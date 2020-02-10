#!/bin/bash


set -ex

root_chroot=$(mktemp -d)


debootstrap \
  --arch=amd64 \
  --variant=minbase \
  sid \
  "${root_chroot}" \
  http://ftp.debian.org/debian/

apt-get update && apt-get install  -y --no-install-recommends \
   equivs
curl -sSL https://gist.githubusercontent.com/heralight/c34fc27048ff8c13862a/raw/2fb11e12df22ef672ea7024a7d0a01863aea576d/gen-dummy-package.sh > /usr/bin/gen-dummy-package.sh

chmod +x /usr/bin/gen-dummy-package.sh

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
   bridge-utils

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

tee "/etc/network/interfaces" <<'EOCI'
auto lo
iface lo inet loopback
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
apt-get install -y --no-install-recommends cri-o-1.16 cri-tools


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
echo "KUBELET_EXTRA_ARGS=--cgroup-driver=systemd" > /etc/default/kubelet
echo "br_netfilter" > /etc/modules-load.d/99-br_netfilter.conf

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


