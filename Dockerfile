FROM debian:bullseye-slim as base-image

ENV root_chroot="/opt/ephemerial-rootfs"
ENV root_image="/opt/ephemerial-image"
ENV boot_src="/opt/grub"
ENV iso_image="/srv/ephemerial.iso"

SHELL ["bash", "-exc"]

RUN apt-get update ;\
    apt-get dist-upgrade -y ;\
    rm -rf /var/lib/apt/lists/*

COPY assets/utils /opt/assets/utils/



FROM base-image as rootfs-builder

RUN apt-get update ;\
    apt-get install -y --no-install-recommends  \
        debootstrap \
        equivs \
        curl \
        ca-certificates ;\
    rm -rf /var/lib/apt/lists/*

# Build base chroot
RUN mkdir -p ${root_chroot} ;\
    debootstrap \
      --arch=amd64 \
      --variant=minbase \
      bullseye \
      "${root_chroot}" \
      http://ftp.debian.org/debian/

# NOTE: We install a dummy ifupdown package to satisfy cloud-init deps, which are currently broken
RUN TMP_DIR=$(mktemp -d) ;\
    cd ${TMP_DIR} ;\
    /opt/assets/utils/gen-dummy-package.sh ifupdown ;\
    cp -v ifupdown*.deb ${root_chroot}/opt/ifupdown.deb ;\
    chroot "${root_chroot}" apt-get install -y /opt/ifupdown.deb ;\
    chroot "${root_chroot}" apt-mark hold ifupdown ;\
    rm ${root_chroot}/opt/ifupdown.deb

RUN chroot "${root_chroot}" apt-get update ;\
    chroot "${root_chroot}" apt-get install  -y --no-install-recommends \
        apt-transport-https \
        linux-image-amd64 \
        live-boot \
        systemd-sysv \
        isc-dhcp-client \
        openssh-server \
        curl \
        gnupg2 \
        iptables \
        cloud-init \
        sudo \
        netplan.io \
        locales-all \
        ipvsadm \
        bridge-utils \
        gettext-base \
        xz-utils \
        conntrack \
        ethtool \
        socat \
        iptables \
        arptables \
        ebtables \
        ifenslave \
        bridge-utils \
        tcpdump \
        iputils-ping \
        vlan ;\
    chroot "${root_chroot}" apt-get autoremove -y ;\
    rm -rf ${root_chroot}/var/lib/apt/lists/* ;\
    rm -f ${root_chroot}/etc/machine-id ;\
    chroot "${root_chroot}" systemctl mask ssh.socket ;\
    chroot "${root_chroot}" update-alternatives --set iptables /usr/sbin/iptables-legacy ;\
    chroot "${root_chroot}" update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy ;\
    chroot "${root_chroot}" update-alternatives --set arptables /usr/sbin/arptables-legacy ;\
    chroot "${root_chroot}" update-alternatives --set ebtables /usr/sbin/ebtables-legacy

RUN echo 'deb http://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/Debian_Testing/ /' > ${root_chroot}/etc/apt/sources.list.d/devel:kubic:libcontainers:stable.list ;\
    curl -o ${root_chroot}/tmp/Release.key -sSL https://download.opensuse.org/repositories/devel:kubic:libcontainers:stable/Debian_Testing/Release.key ;\
    chroot "${root_chroot}" apt-key add /tmp/Release.key ;\
    rm -f  ${root_chroot}/tmp/Release.key ;\
    curl -o ${root_chroot}/tmp/Release.key -sSL https://packages.cloud.google.com/apt/doc/apt-key.gpg ;\
    chroot "${root_chroot}" apt-key add /tmp/Release.key ;\
    rm -f ${root_chroot}/tmp/Release.key ;\
    echo 'deb https://apt.kubernetes.io/ kubernetes-xenial main' > ${root_chroot}/etc/apt/sources.list.d/kubernetes.list

RUN chroot "${root_chroot}" apt-get update ;\
    chroot "${root_chroot}" apt-get install -y --no-install-recommends \
        cri-o-1.16 \
        cri-tools \
        skopeo ;\
    chroot "${root_chroot}" systemctl disable crio

RUN chroot "${root_chroot}" apt-get update ;\
    chroot "${root_chroot}" apt-get install -y --no-install-recommends \
        kubeadm \
        kubectl \
        kubelet \
        kubernetes-cni ;\
    chroot "${root_chroot}" rm -fv /etc/systemd/system/multi-user.target.wants/kubelet.service

RUN chroot "${root_chroot}" crio config > ${root_chroot}/etc/crio/crio.conf ;\
    sed -i 's|runtime_path = ""|runtime_path = "/usr/lib/cri-o-runc/sbin/runc"|g' ${root_chroot}/etc/crio/crio.conf ;\
    sed -i 's|cgroup_manager = "cgroupfs"|cgroup_manager = "systemd"|g' ${root_chroot}/etc/crio/crio.conf ;\
    sed -i 's|log_to_journald = false|log_to_journald = true|g' ${root_chroot}/etc/crio/crio.conf

COPY assets/rootfs /opt/assets/rootfs/
RUN cp -ravf /opt/assets/rootfs/* ${root_chroot}/ ;\
    chroot "${root_chroot}" apt-get autoremove -y ;\
    chroot "${root_chroot}" apt-get reinstall linux-image-$(ls ${root_chroot}/lib/modules) ;\
    rm -rf  ${root_chroot}/var/lib/apt/lists/*

# NOTE: Create a tarball with all the k8s images
#RUN mkdir -p ${root_chroot}/opt/kubeadm-images/images ;\
#    for image_ref in $(chroot "${root_chroot}" kubeadm config images list); do \
#      image_archive="/opt/kubeadm-images/images/$(echo ${image_ref} | tr ':' '-'| tr '/' '_')" ;\
#      echo ${image_ref} ${image_archive} >> ${root_chroot}/opt/kubeadm-images/manifest ;\
#      chroot "${root_chroot}" skopeo copy docker://${image_ref} docker-archive:${image_archive}:${image_ref} ;\
#    done ;\
#    tar -c -J -f ${root_chroot}/opt/kubeadm-images.tar.xz ${root_chroot}/opt/kubeadm-images/ ;\
#    rm -rf ${root_chroot}/opt/kubeadm-images/



FROM base-image as squashfs-builder

RUN apt-get update ;\
    apt-get dist-upgrade -y ;\
    apt-get install -y --no-install-recommends  \
        squashfs-tools ;\
    rm -rf /var/lib/apt/lists/*

COPY --from=rootfs-builder /opt/ephemerial-rootfs ${root_chroot}

RUN mkdir -p ${root_image}/live ;\
    mksquashfs \
        "${root_chroot}" \
        "${root_image}/live/filesystem.squashfs" \
        -processors $(grep -c ^processor /proc/cpuinfo) \
        -e boot ;\
    cp -v "${root_chroot}"/boot/vmlinuz-* "${root_image}"/vmlinuz ;\
    cp -v "${root_chroot}"/boot/initrd.img-* "${root_image}"/initrd ;\
    touch "${root_image}/AIRSHIP_EPHEMERAL"



FROM base-image as grub-builder

RUN apt-get update ;\
    apt-get dist-upgrade -y ;\
    apt-get install -y --no-install-recommends  \
        grub-common \
        grub-pc-bin

COPY assets/grub ${boot_src}

RUN grub-mkstandalone \
        --format=i386-pc \
        --output="${boot_src}/core.img" \
        --install-modules="linux normal iso9660 biosdisk memdisk search tar ls all_video" \
        --modules="linux normal iso9660 biosdisk search" \
        --locales="" \
        --fonts="" \
        boot/grub/grub.cfg="${boot_src}/grub.cfg" ;\
    cat /usr/lib/grub/i386-pc/cdboot.img "${boot_src}/core.img" > "${boot_src}/bios.img"



FROM base-image as iso-builder

RUN apt-get update ;\
    apt-get dist-upgrade -y ;\
    apt-get install -y --no-install-recommends  \
        xorriso \
        grub-pc-bin

COPY assets/utils /opt/assets/utils/
COPY --from=squashfs-builder /opt/ephemerial-image ${root_image}
COPY --from=grub-builder /opt/grub ${boot_src}

ENV cloud_data_root="${root_image}/openstack/latest"
COPY cloud-init ${cloud_data_root}

CMD /opt/assets/utils/build-iso.sh
