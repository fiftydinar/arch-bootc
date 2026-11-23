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

# Build the GRUB EFI payload for bootupd's update tree, and rebuild blsuki.mod
# with a patch to fix duplicate BLS entries.
#
# The payload goes into /usr/lib/efi/<component>/<version>/EFI, which is the
# layout bootupd reads for its EFI update metadata. The component directory must
# be named "grub2", not "grub": bootupd derives the metadata name from that
# directory (get_efi_component_from_usr) and only recognises "grub2" as the
# GRUB bootloader (Bootloader::try_from_efi_component_name), so any other name
# would make the component invisible and leave ::Grub out of
# available_bootloaders(). The EFI/ subdirectory below it is copied as-is, so
# Arch's EFI/arch layout is preserved.
COPY patches/blsuki /tmp/patches/blsuki
RUN pacman -Syu --noconfirm gcc make wget flex bison python patch diffutils && \
    GRUB_VERSION="$(pacman -Qi grub | sed -n 's/^Version *: //p')" && \
    # Extract upstream version (strip epoch like "2:" and pkgrel like "-1")
    GRUB_UPSTREAM="$(echo "$GRUB_VERSION" | sed 's/^[0-9]*://; s/-[0-9].*$//')" && \
    mkdir -p "/usr/lib/efi/grub2/${GRUB_VERSION}/EFI/arch" && \
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
      -o "/usr/lib/efi/grub2/${GRUB_VERSION}/EFI/arch/grubx64.efi" \
      -p /EFI/arch ext2 part_gpt normal configfile search chain boot linux fat btrfs xfs blsuki && \
    cp /usr/lib/efi/grub2/${GRUB_VERSION}/EFI/arch/grubx64.efi "/usr/lib/efi/grub2/${GRUB_VERSION}/EFI/arch/shimx64.efi" && \
    mkdir -p "/usr/lib/efi/grub2/${GRUB_VERSION}/EFI/BOOT" && \
    cp /usr/lib/efi/grub2/${GRUB_VERSION}/EFI/arch/grubx64.efi "/usr/lib/efi/grub2/${GRUB_VERSION}/EFI/BOOT/BOOTX64.EFI"

# Build bootupd from source. It is not in Arch's repos and was removed from
# the bootc repo, but the ostree backend needs it to update GRUB on installed
# systems. Upstream assumes Fedora's layout (grub2-install, /usr/bin/grub2-editenv,
# /boot/grub2); Arch ships grub-install, grub-editenv and keeps its config in
# /boot/grub, so patches/bootupd/0001-* retargets those paths before building.
#
# Note what 0.4.0's "distribution agnostic" work did and did not cover: the
# *package manager* is now pluggable (packagesystem/query-file-owner-{rpm,dpkg,
# pacman,apk}, selected by PACKAGESYSTEM), but the GRUB paths above are still
# hardcoded to Fedora's, so our patch is still required. PACKAGESYSTEM=pacman is
# mandatory: the default is rpm, and installing the rpm query script on Arch
# would leave bootupd shelling out to a binary that does not exist.
#
# The install targets mirror the removed package's package() function:
#   install              -> /usr/libexec/bootupd, /usr/bin/bootupctl and
#                           /usr/lib/bootupd/packagesystem/query-file-owner
#                           (via the query-file-$(PACKAGESYSTEM) prerequisite)
#   install-grub-static  -> /usr/lib/bootupd/grub2-static (needed below)
#   install-systemd-unit -> bootloader-update.service, plus the
#                           bootupd-varlink.{service,socket} API units (new in
#                           0.3.0; both are ConditionPathExists=/sys/firmware/efi
#                           and stay disabled unless something enables them, so
#                           they do not change how the image boots)
# The toolchain is removed again in the same layer, so it does not ship.
COPY patches/bootupd /tmp/patches/bootupd
RUN pacman -Syu --noconfirm rust make git openssl pkgconf && \
    BOOTUPD_TAG=v0.4.0 && \
    git clone --depth 1 --branch "$BOOTUPD_TAG" https://github.com/coreos/bootupd.git /tmp/bootupd && \
    cd /tmp/bootupd && \
    git apply /tmp/patches/bootupd/0001-Modify-grub-paths-to-match-Arch-Linux.patch && \
    cargo fetch --locked --target "$(rustc -vV | sed -n 's/host: //p')" && \
    make && \
    make DESTDIR=/ install install-grub-static install-systemd-unit PACKAGESYSTEM=pacman && \
    # Fail loudly if the Arch path patch ever stops taking effect: a bootupd
    # looking for Fedora's layout silently never updates the bootloader.
    test -L /usr/bin/bootupctl || { echo "ERROR: /usr/bin/bootupctl missing"; exit 1; } && \
    test -f /usr/lib/bootupd/packagesystem/query-file-owner || { echo "ERROR: query-file-owner missing"; exit 1; } && \
    grep -q pacman /usr/lib/bootupd/packagesystem/query-file-owner || { echo "ERROR: query-file-owner is not the pacman variant"; exit 1; } && \
    # The patch must be visible in the built binary, not just in the source tree.
    grep -aq 'usr/bin/grub-install' /usr/libexec/bootupd || { echo "ERROR: bootupd still looks for Fedora's grub2-install"; exit 1; } && \
    if grep -aq 'usr/sbin/grub2-install' /usr/libexec/bootupd; then echo "ERROR: Fedora grub2-install path still compiled in"; exit 1; fi && \
    # Generate EFI.json/BIOS.json with bootupd itself rather than hand-writing
    # them. They used to be written by hand because 0.2.34 hardcoded rpm: BIOS
    # metadata came from `rpm -q --queryformat ... -f`, which does not exist on
    # Arch. 0.4.0 resolves the owning package through the pluggable
    # packagesystem/query-file-owner script instead, installed as the pacman
    # variant above, so the native generator works now.
    # EFI metadata never needed rpm: generate_meta_from_usr_efi derives it from
    # the /usr/lib/efi/<name>/<version>/EFI directory names. It still has to run
    # here rather than earlier, because bootupctl does not exist until now.
    # The verb lives under the hidden `backend` group (bootupctl dispatches on
    # argv[0]; `generate-update-metadata` is otherwise only a bootupd verb).
    # This is the same invocation upstream's own test harness uses, see
    # tests/tests/generate-update-metadata.sh.
    bootupctl backend generate-update-metadata -vvv && \
    # bootupctl skips a component it cannot handle instead of failing, so a
    # missing metadata file is the signal that generation silently did nothing.
    test -s /usr/lib/bootupd/updates/BIOS.json || { echo "ERROR: BIOS.json not generated"; exit 1; } && \
    test -s /usr/lib/bootupd/updates/EFI.json || { echo "ERROR: EFI.json not generated"; exit 1; } && \
    grep -Eq '"name": ?"grub2"' /usr/lib/bootupd/updates/EFI.json || { echo "ERROR: EFI.json does not name grub2 (won't be seen as GRUB)"; cat /usr/lib/bootupd/updates/EFI.json; exit 1; } && \
    grep -Eq '"name": ?"grub"' /usr/lib/bootupd/updates/BIOS.json || { echo "ERROR: BIOS.json does not name the grub package"; cat /usr/lib/bootupd/updates/BIOS.json; exit 1; } && \
    echo "--- bootupd updates/BIOS.json ---" && cat /usr/lib/bootupd/updates/BIOS.json && echo && \
    echo "--- bootupd updates/EFI.json ---" && cat /usr/lib/bootupd/updates/EFI.json && echo && \
    # Override bootupd's default GRUB configs with our custom versions
    # The EFI stub config uses direct blscfg instead of chaining to the main config,
    # avoiding duplicate entries caused by bootupd's generated main config also calling blscfg.
    rm -f /usr/lib/bootupd/grub2-static/configs.d/10_blscfg.cfg && \
    cp /tmp/patches/bootupd/grub-static-efi.cfg /usr/lib/bootupd/grub2-static/grub-static-efi.cfg && \
    cp /tmp/patches/bootupd/10_blscfg.cfg /usr/lib/bootupd/grub2-static/configs.d/10_blscfg.cfg && \
    cd / && rm -rf /tmp/bootupd /tmp/patches/bootupd && \
    # pkgconf is deliberately NOT in this list: dracut depends on it at runtime,
    # so 'pacman -R ... pkgconf' aborted the whole transaction ("removing pkgconf
    # breaks dependency 'pkgconf' required by dracut") and left the toolchain in
    # this layer - rust alone is ~440MiB. Because the install and the removal
    # happen in the same RUN, a failed removal means rust/make/git ship inside
    # this layer permanently; a later layer removing them only adds whiteouts.
    pacman -R --noconfirm rust make git && \
    for _p in rust make git; do if pacman -Q "$_p" >/dev/null 2>&1; then echo "ERROR: $_p still installed after cleanup, layer is bloated"; exit 1; fi; done && \
    pacman -Scc --noconfirm

# Build bootc with bcachefs support from source.
#
# bcachefs is out of mainline and bootc does not accept it, so
# patches/bootc/0001-bcachefs-support.patch backports upstream PR #2661 on top
# of v1.17.5 (it cherry-picks with no conflicts). That replaces our earlier
# three-hunk patch, which only taught `to-disk` to mkfs.bcachefs and, unlike the
# PR, had no guard against an unbootable layout: with GRUB a bcachefs root needs
# a separate /boot on a filesystem GRUB can read, and the old patch let
# `--filesystem bcachefs` wipe the target and only then fail. The PR checks that
# before --wipe, and also resolves multi-device roots and recovers the fs UUID
# from blkid when udev is unavailable. Delete the patch once a release contains
# the PR.
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
#
# Expected result: `bootc container lint` (last step) warns
#   Lint warning: runtime-deps: Missing required runtime dependencies: chcon
# That is a false positive, and there is nothing to install: the lint reads a
# static list from [workspace.metadata.binary-dependencies] without consulting
# the enabled cargo features, so it asks for chcon on SELinux-free builds too.
# chcon cannot run here: it is only invoked by test_install_t(), which is
# reached solely through selinux_ensure_install(); the two call sites are gated
# on lsm::selinux_enabled() (compiled to `false` without the feature) and on
# srcdata.selinux (whether the source image has etc/selinux/config, which this
# image does not). The lint itself is new in 1.17.x; v1.16.10 had no
# runtime-deps check at all, which is why this warning did not appear before.
COPY patches/bootc /tmp/patches/bootc
RUN pacman -Syu --noconfirm make rust go-md2man git wget && \
    BOOTC_TAG=v1.17.5 && \
    BOOTC_CARGO_OPTIONS='--no-default-features --features "install-to-disk pre-6.15"' && \
    git clone --depth 1 --branch "$BOOTC_TAG" https://github.com/bootc-dev/bootc.git /tmp/bootc && \
    cd /tmp/bootc && \
    git apply /tmp/patches/bootc/0001-bcachefs-support.patch && \
    # Fail loudly if the backport ever stops applying: without it bootc has no
    # bcachefs at all, and the installer would silently lose the filesystem.
    grep -q Bcachefs crates/lib/src/install/config.rs || { echo "ERROR: bcachefs patch did not take effect"; exit 1; } && \
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
