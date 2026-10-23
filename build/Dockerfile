FROM debian:trixie
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential debhelper devscripts fakeroot lintian shellcheck bats \
        aptly gnupg ca-certificates curl \
        mkosi apt debian-archive-keyring systemd-container systemd-repart \
        systemd-boot systemd-boot-efi systemd-ukify dosfstools mtools e2fsprogs zstd cpio \
        qemu-system-x86 qemu-utils ovmf openssh-client \
    && rm -rf /var/lib/apt/lists/*
