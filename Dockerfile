FROM debian:buster-slim

RUN apt-get update && apt-get install -y \
    debootstrap \
    grub-efi-amd64-bin \
    grub-pc-bin \
    mtools \
    squashfs-tools \
    xorriso \
    curl\
    && rm -rf /var/lib/apt/lists/*
RUN curl -L https://github.com/mikefarah/yq/releases/download/2.4.0/yq_linux_amd64 -o /bin/yq \
    && chmod +x /bin/yq

COPY build.sh /usr/local/bin/build.sh

CMD /usr/local/bin/build.sh

