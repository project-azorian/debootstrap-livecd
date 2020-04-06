#!/bin/bash
set -ex
mkdir -p "$(dirname "${iso_image}")"
xorriso \
  -as mkisofs \
  -iso-level 3 \
  -full-iso9660-filenames \
  -volid "config-2" \
  --grub2-boot-info \
  --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
  -eltorito-boot boot/grub/bios.img \
  -no-emul-boot \
  -boot-load-size 4 \
  -boot-info-table \
  --eltorito-catalog boot/grub/boot.cat \
  -output "${iso_image}" \
  -graft-points \
    "${root_image}" \
    /boot/grub/bios.img="${boot_src}/bios.img"
