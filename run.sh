#!/bin/bash
set -ex
rm -f ephemerial.iso
docker build .  -t port/debootstrap-livecd:latest
docker run -it --rm -v $(pwd):/srv port/debootstrap-livecd:latest
