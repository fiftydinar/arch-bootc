FROM docker.io/archlinux/archlinux:latest

# Move everything from `/var` to `/usr/lib/sysimage` so behavior around pacman remains the same on `bootc usroverlay`'d systems
RUN grep "= */var" /etc/pacman.conf | sed "/= *\/var/s/.*=// ; s/ //" | xargs -n1 sh -c 'mkdir -p "/usr/lib/sysimage/$(dirname $(echo $1 | sed "s@/var/@@"))" && mv -v "$1" "/usr/lib/sysimage/$(echo "$1" | sed "s@/var/@@")"' '' && \
    sed -i -e "/= *\/var/ s/^#//" -e "s@= */var@= /usr/lib/sysimage@g" -e "/DownloadUser/d" /etc/pacman.conf

# Remove NoExtract rules, otherwise no additional languages and help pages can be installed
# See https://gitlab.archlinux.org/archlinux/archlinux-docker/-/blob/master/pacman-conf.d-noextract.conf?ref_type=heads
RUN sed -i 's/^[[:space:]]*NoExtract/#&/' /etc/pacman.conf

# Add bootc package repo
RUN pacman-key --init && \
    pacman-key --populate && \
    pacman-key --recv-key 5DE6BF3EBC86402E7A5C5D241FA48C960F9604CB --keyserver keyserver.ubuntu.com && \
    pacman-key --lsign-key 5DE6BF3EBC86402E7A5C5D241FA48C960F9604CB && \
    echo -e '[bootc]\nSigLevel = Required\nServer=https://github.com/hecknt/arch-bootc-pkgs/releases/download/$repo' >> /etc/pacman.conf

# Install base bootc-related packages
# bootc is built from source below (not from the repo) for bcachefs support
# bootupd is built from source below too: it was dropped from the bootc repo
# (hecknt/arch-bootc-pkgs@da9729e) after its maintainer deemed the patches
# unreliable, and Arch itself does not package it. That package used to pull in
# grub and efibootmgr implicitly, so both are listed explicitly here: the GRUB
# blsuki rebuild below reads the installed grub version, and bootupd drives
# grub-install/efibootmgr when updating the bootloader on installed systems.
RUN pacman -Syu --noconfirm base cpio dracut linux linux-firmware ostree btrfs-progs e2fsprogs xfsprogs dosfstools skopeo podman grub efibootmgr sudo dbus dbus-glib glib2 ostree shadow glibc && pacman -Scc --noconfirm

# Create bootupd update metadata for EFI and BIOS components directly
# (bootupd's generate-update-metadata tries to run rpm for BIOS, which is
# not available on Arch — manual JSON is cleaner)
# Also rebuild blsuki.mod with a patch to fix duplicate BLS entries
COPY patches/blsuki /tmp/patches/blsuki
RUN pacman -Syu --noconfirm gcc make wget flex bison python patch diffutils && \
    GRUB_VERSION="$(pacman -Qi grub | sed -n 's/^Version *: //p')" && \
    # Extract upstream version (strip epoch like "2:" and pkgrel like "-1")
    GRUB_UPSTREAM="$(echo "$GRUB_VERSION" | sed 's/^[0-9]*://; s/-[0-9].*$//')" && \
    mkdir -p "/usr/lib/efi/grub/${GRUB_VERSION}/EFI/arch" && \
    # Download GRUB source matching installed version
    wget -qO- "https://ftp.gnu.org/gnu/grub/grub-${GRUB_UPSTREAM}.tar.xz" | tar xJ -C /tmp && \
    cd /tmp/grub-${GRUB_UPSTREAM} && \
    # Patch blsuki.c to use grub_strcmp instead of filevercmp
    patch -p1 < /tmp/patches/blsuki/0001-fix-duplicate-detection.patch && \
    # Configure for x86_64-efi target
    ./configure --with-platform=efi --target=x86_64 --disable-werror --prefix=/usr \
      --disable-nls --disable-grub-mkfont --disable-grub-mount --disable-grub-mkrescue \
      --disable-efiemu 2>&1 | tail -3 && \
    # Touch pre-generated lexer/yacc files to prevent regeneration
    touch -c grub-core/script/*-lexer.c grub-core/script/*-yacc.c 2>/dev/null; true && \
    make -C grub-core blsuki.mod 2>&1 && \
    if [ -f grub-core/blsuki.mod ]; then \
      cp grub-core/blsuki.mod /usr/lib/grub/x86_64-efi/blsuki.mod; \
    fi && \
    # Also rebuild for i386-pc (BIOS)
    make clean 2>/dev/null; true && \
    ./configure --with-platform=pc --target=i386 --disable-werror --prefix=/usr \
      --disable-nls --disable-grub-mkfont --disable-grub-mount --disable-grub-mkrescue \
      --disable-efiemu 2>&1 | tail -3 && \
    touch -c grub-core/script/*-lexer.c grub-core/script/*-yacc.c 2>/dev/null; true && \
    make -C grub-core blsuki.mod 2>&1 && \
    if [ -f grub-core/blsuki.mod ] && [ -d /usr/lib/grub/i386-pc ]; then \
      cp grub-core/blsuki.mod /usr/lib/grub/i386-pc/blsuki.mod; \
    fi && \
    cd / && rm -rf /tmp/grub-${GRUB_UPSTREAM} && \
    pacman -R --noconfirm gcc make wget flex bison patch 2>/dev/null; true && \
    pacman -Scc --noconfirm && \
    grub-mkimage -O x86_64-efi \
      -o "/usr/lib/efi/grub/${GRUB_VERSION}/EFI/arch/grubx64.efi" \
      -p /EFI/arch ext2 part_gpt normal configfile search chain boot linux fat btrfs xfs blsuki && \
    cp /usr/lib/efi/grub/${GRUB_VERSION}/EFI/arch/grubx64.efi "/usr/lib/efi/grub/${GRUB_VERSION}/EFI/arch/shimx64.efi" && \
    mkdir -p "/usr/lib/efi/grub/${GRUB_VERSION}/EFI/BOOT" && \
    cp /usr/lib/efi/grub/${GRUB_VERSION}/EFI/arch/grubx64.efi "/usr/lib/efi/grub/${GRUB_VERSION}/EFI/BOOT/BOOTX64.EFI" && \
    TS="$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" && \
    mkdir -p /usr/lib/bootupd/updates && \
    printf '{"timestamp":"%s","version":"grub2-%s","versions":[{"name":"grub2","rpm_evr":"%s"}]}' \
      "$TS" "$GRUB_VERSION" "$GRUB_VERSION" \
      > /usr/lib/bootupd/updates/EFI.json && \
    printf '{"timestamp":"%s","version":"grub2-%s","versions":[{"name":"grub2","rpm_evr":"%s"}]}' \
      "$TS" "$GRUB_VERSION" "$GRUB_VERSION" \
      > /usr/lib/bootupd/updates/BIOS.json

# Build bootupd from source. It is not in Arch's repos and was removed from
# the bootc repo, but the ostree backend needs it to update GRUB on installed
# systems. Upstream assumes Fedora's layout (grub2-install, /boot/grub2,
# grub2-mkimage); Arch ships grub-install and keeps its config in /boot/grub,
# so patches/bootupd/0001-* retargets those paths before building.
#
# The install targets mirror the removed package's package() function:
#   install              -> /usr/libexec/bootupd + /usr/bin/bootupctl
#   install-grub-static  -> /usr/lib/bootupd/grub2-static (needed below)
#   install-systemd-unit -> bootloader-update.service
# The toolchain is removed again in the same layer, so it does not ship.
COPY patches/bootupd /tmp/patches/bootupd
RUN pacman -Syu --noconfirm rust make git openssl pkgconf && \
    BOOTUPD_TAG=v0.2.34 && \
    git clone --depth 1 --branch "$BOOTUPD_TAG" https://github.com/coreos/bootupd.git /tmp/bootupd && \
    cd /tmp/bootupd && \
    git apply /tmp/patches/bootupd/0001-Modify-grub-paths-to-match-Arch-Linux.patch && \
    # Arch moved to OpenSSL 4.x, which the openssl-sys version in bootupd's
    # lockfile (0.9.112) refuses to build against:
    #   This crate is only compatible with OpenSSL (version 1.1.0, 1.1.1, or
    #   3.x), or LibreSSL 3.5.0 through 4.2.x, but a different version of
    #   OpenSSL was found.
    # openssl-sys 0.9.114+ accepts 4.x, so move the lockfile forward to the
    # matching openssl/openssl-sys pair. Only these two crates move.
    cargo update -p openssl --precise 0.10.82 && \
    cargo fetch --locked --target "$(rustc -vV | sed -n 's/host: //p')" && \
    make && \
    make DESTDIR=/ install install-grub-static install-systemd-unit && \
    # Override bootupd's default GRUB configs with our custom versions
    # The EFI stub config uses direct blscfg instead of chaining to the main config,
    # avoiding duplicate entries caused by bootupd's generated main config also calling blscfg.
    rm -f /usr/lib/bootupd/grub2-static/configs.d/10_blscfg.cfg && \
    cp /tmp/patches/bootupd/grub-static-efi.cfg /usr/lib/bootupd/grub2-static/grub-static-efi.cfg && \
    cp /tmp/patches/bootupd/10_blscfg.cfg /usr/lib/bootupd/grub2-static/configs.d/10_blscfg.cfg && \
    cd / && rm -rf /tmp/bootupd /tmp/patches/bootupd && \
    (pacman -R --noconfirm rust make git pkgconf 2>/dev/null || true) && \
    pacman -Scc --noconfirm

# Build bootc with bcachefs support from source.
#
# Built with SELinux support disabled. Arch packages neither libselinux nor
# libsepol, and this image is deliberately SELinux-free, so the default build
# cannot link. Upstream issue #2431 made this a supported build mode in v1.17.0:
# `selinux` became an optional cargo feature, still on by default, so it has to
# be dropped with --no-default-features and the wanted defaults added back.
#
# --no-default-features applies to the whole workspace, not just bootc's own
# crate, so every default we still need is listed explicitly:
#   install-to-disk  bootc-lib: disk installation support
#   pre-6.15         bootc-initramfs-setup: composefs loopback fallback for
#                    kernels older than 6.15
# This is the exact incantation upstream documents in
# docs/src/bootc-packaging-and-integration.7.md. Such a build treats SELinux as
# disabled on the host: it never reads selinuxfs, never enters the install_t
# domain and never parses SELinux contexts. Verified with
#   cargo tree --no-default-features --features "install-to-disk pre-6.15"
# which drops selinux and selinux-sys from the graph and changes nothing else.
#
# install-all must not rebuild the binary with default features, so it gets the
# same CARGO_OPTIONS and SKIP_BUILD=1: `install` depends on `completion`, which
# depends on `bin`, and a bare `make install-all` would otherwise recompile with
# SELinux and fail.
COPY patches/bootc /tmp/patches/bootc
RUN pacman -Syu --noconfirm make rust go-md2man git wget && \
    BOOTC_TAG=v1.17.5 && \
    BOOTC_CARGO_OPTIONS='--no-default-features --features "install-to-disk pre-6.15"' && \
    git clone --depth 1 --branch "$BOOTC_TAG" https://github.com/bootc-dev/bootc.git /tmp/bootc && \
    cd /tmp/bootc && \
    git apply /tmp/patches/bootc/0001-add-bcachefs-filesystem-support.patch && \
    cargo fetch --locked --target "$(rustc -vV | sed -n 's/host: //p')" && \
    make bin CARGO_OPTIONS="$BOOTC_CARGO_OPTIONS" && \
    make DESTDIR=/ install-all CARGO_OPTIONS="$BOOTC_CARGO_OPTIONS" SKIP_BUILD=1 && \
    # Fail loudly if this ever regresses: a rebuild that silently picked up the
    # default features again would link libselinux, which does not exist here.
    if ldd /usr/bin/bootc | grep -q libselinux; then echo "ERROR: bootc links libselinux, the SELinux-free build flags were lost"; exit 1; fi && \
    bootc --version | grep -qx "bootc ${BOOTC_TAG#v}" || { echo "ERROR: bootc version is not ${BOOTC_TAG#v}"; bootc --version; exit 1; } && \
    cd / && rm -rf /tmp/bootc /tmp/bootc-target /tmp/patches && \
    pacman -R --noconfirm make rust go-md2man git && \
    pacman -Scc --noconfirm

# Necessary for general behavior expected by image-based systems
RUN printf "systemdsystemconfdir=/etc/systemd/system\nsystemdsystemunitdir=/usr/lib/systemd/system\n" | tee /usr/lib/dracut/dracut.conf.d/30-bootcrew-fix-bootc-module.conf && \
    printf 'reproducible=yes\nhostonly=no\ncompress=zstd\nadd_dracutmodules+=" ostree bootc "\nadd_drivers+=" xfs btrfs "' | tee "/usr/lib/dracut/dracut.conf.d/30-bootcrew-bootc-container-build.conf" && \
    dracut --force "$(find /usr/lib/modules -maxdepth 1 -type d | grep -v -E "\.img" | tail -n 1)/initramfs.img" && \
    sed -i 's|^HOME=.*|HOME=/var/home|' "/etc/default/useradd" && \
    rm -rf /boot /home /root /usr/local /srv /opt /mnt /var /usr/lib/sysimage/log /usr/lib/sysimage/cache/pacman/pkg && \
    mkdir -p /sysroot /boot /usr/lib/ostree /var && \
    ln -sT sysroot/ostree /ostree && ln -sT var/roothome /root && ln -sT var/srv /srv && ln -sT var/opt /opt && ln -sT var/mnt /mnt && ln -sT var/home /home && ln -sT ../var/usrlocal /usr/local && \
    echo "$(for dir in opt home srv mnt usrlocal ; do echo "d /var/$dir 0755 root root -" ; done)" | tee -a "/usr/lib/tmpfiles.d/bootc-base-dirs.conf" && \
    printf "d /var/roothome 0700 root root -\nd /run/media 0755 root root -" | tee -a "/usr/lib/tmpfiles.d/bootc-base-dirs.conf" && \
    printf '[composefs]\nenabled = yes\n[sysroot]\nreadonly = true\n' | tee "/usr/lib/ostree/prepare-root.conf" && \
    mkdir -p /usr/lib/bootc/install && \
    echo -e '[install]\nbootloader = "grub"' > /usr/lib/bootc/install/00-arch-bootc.toml

# bootc-image-builder cannot parse Arch's multi-dot VERSION_ID (e.g. 20260716.0.557185)
# Override to a format it accepts: YYYYMMDD.rolling
RUN sed -i "s/^VERSION_ID=.*/VERSION_ID=$(date +%Y%m%d)/" /etc/os-release

# https://bootc-dev.github.io/bootc/bootc-images.html#standard-metadata-for-bootc-compatible-images
LABEL containers.bootc 1

RUN bootc container lint
