#!/bin/bash
set -ex
sudo podman build . -t debootstrap-livecd
output=$(pwd | sed "s|^${HOME}/Development/Source|${HOME}/Development/Build|")
mkdir -p ${output}
rm -rf ${output}/debian-custom.iso
sudo podman run -it --rm --privileged -v ${output}:/srv:rw debootstrap-livecd /usr/local/bin/build.sh
ls -lh ${output}
sudo cp ${output}/debian-custom.iso /var/lib/libvirt/boot/debian-custom.iso
