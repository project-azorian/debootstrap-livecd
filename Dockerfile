FROM debian:sid-slim

RUN set -ex ;\
    apt-get update ;\
    apt-get dist-upgrade -y ;\
    apt-get install -y --no-install-recommends  \
    debootstrap \
    grub-efi-amd64-bin \
    grub-pc-bin \
    mtools \
    squashfs-tools \
    xorriso \
    curl \
    equivs \
    ca-certificates ;\
    rm -rf /var/lib/apt/lists/*

RUN set -ex ;\
    curl -L https://github.com/mikefarah/yq/releases/download/2.4.0/yq_linux_amd64 -o /bin/yq ;\
    chmod +x /bin/yq

RUN set -ex ;\
    curl -sSL https://gist.githubusercontent.com/heralight/c34fc27048ff8c13862a/raw/2fb11e12df22ef672ea7024a7d0a01863aea576d/gen-dummy-package.sh > /usr/bin/gen-dummy-package.sh ;\
    chmod +x /usr/bin/gen-dummy-package.sh

COPY assets /opt/assets/

COPY build.sh /usr/local/bin/build.sh

CMD /usr/local/bin/build.sh

