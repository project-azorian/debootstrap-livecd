#!/bin/bash


set -ex

root_chroot=$(mktemp -d)


debootstrap \
  --arch=amd64 \
  --variant=minbase \
  sid \
  "${root_chroot}" \
  http://ftp.debian.org/debian/

/usr/bin/gen-dummy-package.sh ifupdown
cp -v ifupdown*.deb ${root_chroot}/ifupdown.deb

chroot "${root_chroot}" <<'EOF'
apt-get install -y /ifupdown.deb
rm -f /ifupdown.deb
apt-mark hold ifupdown
EOF

chroot "${root_chroot}" <<'EOF'
echo "localhost" > /etc/hostname
echo "127.0.0.1 localhost" > /etc/hosts
apt-get update && apt-get install  -y --no-install-recommends \
   linux-image-amd64 \
   live-boot \
   systemd-sysv \
   isc-dhcp-client \
   openssh-server \
   curl \
   iptables \
   cloud-init \
   sudo \
   netplan.io \
   locales-all \
   ipvsadm \
   bridge-utils \
   gettext-base \
   xz-utils

apt-get autoremove -y
rm -rf /var/lib/apt/lists/*

echo "datasource_list: [ NoCloud, None ]" > "/etc/cloud/cloud.cfg.d/95_no_cloud_ds.cfg"
rm -f /etc/machine-id
EOF

chroot "${root_chroot}" <<'EOF'
tee "/etc/cloud/cloud.cfg.d/user-data.cfg" <<'EOCI'
#cloud-config
password: password
ssh_pwauth: True
chpasswd:
  expire: false
write_files:
  - path: /usr/local/bin/genesis
    permissions: '0711'
    content: |
      #!/bin/bash
      set -ex
      export pod_network_cidr="172.18.0.0/17"
      export svc_network_cidr="172.18.128.0/17"
      export kubeadm_initial_token="$(kubeadm token generate)"
      export kubernetes_release="$(kubelet --version | awk '{ print $NF ; exit }')"
      export default_route_device="$(route -n | awk '/^0.0.0.0/ { print $5 " " $NF }' | sort | awk '{ print $NF; exit }')"
      export default_route_device_ip="$(ip a s $default_route_device | grep 'inet ' | awk '{print $2}' | awk -F "/" '{print $1}' | head -n 1)"
      cat /etc/airship/genesis/100-crio-bridge.conf.template | envsubst > /etc/cni/net.d/100-crio-bridge.conf
      cat /etc/airship/genesis/kubeadm.yaml.template | envsubst > /etc/kubernetes/kubeadm.yaml

      if [[ -f /opt/kubeadm-images.tar.xz ]]; then
        tar -xJf /opt/kubeadm-images.tar.xz -C /
        while IFS="" read -r line || [ -n "$line" ]; do
          image_ref=$(echo $line | awk '{ print $1 }')
          image_archive=$(echo $line | awk '{ print $2 }')
          skopeo copy docker-archive:${image_archive} containers-storage:${image_ref}
          rm -fv ${image_archive}
        done < /opt/kubeadm-images/manifest
        rm -rf /opt/kubeadm-images
      else
        kubeadm config images list --config /etc/kubernetes/kubeadm.yaml
        kubeadm config images pull --config /etc/kubernetes/kubeadm.yaml
      fi
      kubeadm init --config /etc/kubernetes/kubeadm.yaml --ignore-preflight-errors=SystemVerification

      mkdir -p ~/.kube
      rm -f ~/.kube/config
      cp -i /etc/kubernetes/admin.conf ~/.kube/config
      chown $(id -u):$(id -g) ~/.kube/config

      # NOTE: Wait for dns to be running.
      END=$(($(date +%s) + 240))
      until kubectl --namespace=kube-system \
            get pods -l k8s-app=kube-dns --no-headers -o name | grep -q "^pod/coredns"; do
      NOW=$(date +%s)
      [ "${NOW}" -gt "${END}" ] && exit 1
      echo "still waiting for dns"
      sleep 10
      done
      kubectl --namespace=kube-system wait --timeout=240s --for=condition=Ready pods -l k8s-app=kube-dns

      kubectl taint nodes --all node-role.kubernetes.io/master-

      kubectl get nodes -o wide

  - path: /etc/airship/genesis/100-crio-bridge.conf.template
    permissions: '0640'
    content: |
      {
        "cniVersion": "0.3.1",
        "name": "crio-bridge",
        "type": "bridge",
        "bridge": "cni0",
        "isGateway": true,
        "ipMasq": true,
        "hairpinMode": true,
        "ipam": {
          "type": "host-local",
          "routes": [
            { "dst": "0.0.0.0/0" },
            { "dst": "1100:200::1/24" }
          ],
          "ranges": [
            [{ "subnet": "${pod_network_cidr}" }],
            [{ "subnet": "1100:200::/24" }]
          ]
        }
      }
  - path: /etc/airship/genesis/kubeadm.yaml.template
    permissions: '0640'
    content: |
      apiVersion: kubeadm.k8s.io/v1beta2
      kind: InitConfiguration
      localAPIEndpoint:
        advertiseAddress: ${default_route_device_ip}
        bindPort: 6443
      nodeRegistration:
        criSocket: /var/run/crio/crio.sock
        name: ${HOSTNAME}
        taints:
        - effect: NoSchedule
          key: node-role.kubernetes.io/master
      bootstrapTokens:
      - groups:
        - system:bootstrappers:kubeadm:default-node-token
        token: ${kubeadm_initial_token}
        ttl: 24h0m0s
        usages:
        - signing
        - authentication
      ---
      apiVersion: kubeadm.k8s.io/v1beta2
      kind: ClusterConfiguration
      clusterName: kubernetes
      kubernetesVersion: ${kubernetes_release}
      imageRepository: k8s.gcr.io
      networking:
        dnsDomain: cluster.local
        podSubnet: ${pod_network_cidr}
        serviceSubnet: ${svc_network_cidr}
      apiServer:
        extraArgs:
          authorization-mode: Node,RBAC
        timeoutForControlPlane: 4m0s
      certificatesDir: /etc/kubernetes/pki
      controllerManager: {}
      dns:
        type: CoreDNS
      etcd:
        local:
          dataDir: /var/lib/etcd
      scheduler: {}
      ---
      apiVersion: kubeproxy.config.k8s.io/v1alpha1
      kind: KubeProxyConfiguration
      mode: "ipvs"
runcmd:
 - [ /usr/local/bin/genesis ]
EOCI
tee "/etc/cloud/cloud.cfg.d/network-data.cfg" <<'EOCI'
network:
  version: 2
  ethernets:
    # opaque ID for physical interfaces, only referred to by other stanzas
    id0:
      match:
        name: "enp*"
      dhcp4: true
EOCI
sed -i 's/SSHD_OPTS=/SSHD_OPTS=-4/' /etc/default/ssh
mkdir -p /etc/systemd/system/sshd.service.d
tee "/etc/systemd/system/sshd.service.d/wait.conf" <<'EOCI'
[Unit]
Wants=network-online.target
After=network-online.target
EOCI


systemctl mask ssh.socket

EOF


chroot "${root_chroot}" <<'EOF'
apt-get update
apt-get install -y gnupg2

# Debian Unstable/Sid
echo 'deb http://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/Debian_Unstable/ /' > /etc/apt/sources.list.d/devel:kubic:libcontainers:stable.list
curl -o Release.key -sSL https://download.opensuse.org/repositories/devel:kubic:libcontainers:stable/Debian_Unstable/Release.key
apt-key add - < Release.key
rm -f  Release.key

apt-get update
apt-get install -y --no-install-recommends cri-o-1.16 cri-tools skopeo


crio config > /etc/crio/crio.conf
sed -i 's|runtime_path = ""|runtime_path = "/usr/lib/cri-o-runc/sbin/runc"|g' /etc/crio/crio.conf
sed -i 's|cgroup_manager = "cgroupfs"|cgroup_manager = "systemd"|g' /etc/crio/crio.conf

tee /etc/systemd/system/crio-mount.service <<EOU
[Unit]
Description=CRI-O Setup loopback and mount for Overlay
Before=crio-wipe.service

[Service]
ExecStartPre=/usr/bin/mkdir -p /var/lib/containers
ExecStartPre=/usr/bin/truncate -s 16384M /var/lib/containers/graph.img
ExecStartPre=/usr/sbin/mkfs.ext4 /var/lib/containers/graph.img
ExecStartPre=/usr/bin/mkdir -p /var/lib/containers/storage
ExecStart=/usr/bin/mount /var/lib/containers/graph.img /var/lib/containers/storage/

Type=oneshot

[Install]
WantedBy=multi-user.target
EOU

apt-get install -y iptables arptables ebtables

# switch to legacy versions
update-alternatives --set iptables /usr/sbin/iptables-legacy
update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
update-alternatives --set arptables /usr/sbin/arptables-legacy
update-alternatives --set ebtables /usr/sbin/ebtables-legacy

apt-get update
apt-get install -y --no-install-recommends apt-transport-https curl
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
tee /etc/apt/sources.list.d/kubernetes.list <<EOIF
deb https://apt.kubernetes.io/ kubernetes-xenial main
EOIF

apt-get update
apt-get install -y --no-install-recommends kubelet kubeadm kubectl

sed -i 's/^#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.d/99-sysctl.conf
echo "br_netfilter" > /etc/modules-load.d/99-br_netfilter.conf

echo "KUBELET_EXTRA_ARGS=--cgroup-driver=systemd" > /etc/default/kubelet

rm -rf /opt/kubeadm-images
mkdir -p /opt/kubeadm-images/images
for image_ref in $(kubeadm config images list); do
  image_archive="/opt/kubeadm-images/images/$(echo ${image_ref} | tr ':' '-'| tr '/' '_')"
  echo ${image_ref} ${image_archive} >> /opt/kubeadm-images/manifest
  skopeo copy docker://${image_ref} docker-archive:${image_archive}:${image_ref}
done
XZ_OPT=-9e tar -c -J -f /opt/kubeadm-images.tar.xz /opt/kubeadm-images/
rm -rf /opt/kubeadm-images

apt-get autoremove -y
apt-get reinstall linux-image-$(ls /lib/modules)

rm -rf /var/lib/apt/lists/*

EOF

root_image=$(mktemp -d)

mkdir -p "${root_image}"/live
mksquashfs \
  "${root_chroot}" \
  "${root_image}"/live/filesystem.squashfs \
  -processors 8 \
  -e boot

cp -v "${root_chroot}"/boot/vmlinuz-* "${root_image}"/vmlinuz
cp -v "${root_chroot}"/boot/initrd.img-* "${root_image}"/initrd

touch "${root_image}/DEBIAN_CUSTOM"   

ls -lh ${root_chroot}
ls -lh ${root_image}

   
boot_src=$(mktemp -d)
tee "${boot_src}"/grub.cfg <<'EOF'
search --set=root --file /DEBIAN_CUSTOM

insmod all_video

set default="0"
set timeout=1

menuentry "Debian Live" {
    linux /vmlinuz boot=live quiet nomodeset overlay-size=70% systemd.unified_cgroup_hierarchy=0
    initrd /initrd
}
EOF

grub-mkstandalone \
  --format=i386-pc \
  --output="${boot_src}/core.img" \
  --install-modules="linux normal iso9660 biosdisk memdisk search tar ls all_video" \
  --modules="linux normal iso9660 biosdisk search" \
  --locales="" \
  --fonts="" \
  boot/grub/grub.cfg="${boot_src}/grub.cfg"

cat /usr/lib/grub/i386-pc/cdboot.img "${boot_src}/core.img" > "${boot_src}/bios.img"

ls -lh ${boot_src}

output=$(mktemp -d)
xorriso \
  -as mkisofs \
  -iso-level 3 \
  -full-iso9660-filenames \
  -volid "DEBIAN_CUSTOM" \
  --grub2-boot-info \
  --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
  -eltorito-boot boot/grub/bios.img \
  -no-emul-boot \
  -boot-load-size 4 \
  -boot-info-table \
  --eltorito-catalog boot/grub/boot.cat \
  -output "${output}/debian-custom.iso" \
  -graft-points \
    "${root_image}" \
    /boot/grub/bios.img="${boot_src}/bios.img"
mv -v ${output}/debian-custom.iso /srv/debian-custom.iso
ls -lh /srv/debian-custom.iso


