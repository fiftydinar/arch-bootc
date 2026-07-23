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
RUN pacman -Syu --noconfirm base cpio dracut linux linux-firmware ostree btrfs-progs e2fsprogs xfsprogs dosfstools skopeo podman bootupd sudo dbus dbus-glib glib2 ostree shadow glibc && pacman -Scc --noconfirm

# Create bootupd update metadata for EFI and BIOS components directly
# (bootupd's generate-update-metadata tries to run rpm for BIOS, which is
# not available on Arch — manual JSON is cleaner)
RUN GRUB_VERSION="$(pacman -Qi grub | sed -n 's/^Version *: //p')" && \
    mkdir -p "/usr/lib/efi/grub/${GRUB_VERSION}/EFI/arch" && \
    grub-mkimage -O x86_64-efi \
      -o "/usr/lib/efi/grub/${GRUB_VERSION}/EFI/arch/grubx64.efi" \
      -p /EFI/arch ext2 part_gpt normal configfile search chain boot linux fat btrfs xfs blsuki && \
    cp /usr/lib/efi/grub/${GRUB_VERSION}/EFI/arch/grubx64.efi "/usr/lib/efi/grub/${GRUB_VERSION}/EFI/arch/shimx64.efi" && \
    TS="$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" && \
    mkdir -p /usr/lib/bootupd/updates && \
    printf '{"timestamp":"%s","version":"grub2-%s","versions":[{"name":"grub2","rpm_evr":"%s"}]}' \
      "$TS" "$GRUB_VERSION" "$GRUB_VERSION" \
      > /usr/lib/bootupd/updates/EFI.json && \
    printf '{"timestamp":"%s","version":"grub2-%s","versions":[{"name":"grub2","rpm_evr":"%s"}]}' \
      "$TS" "$GRUB_VERSION" "$GRUB_VERSION" \
      > /usr/lib/bootupd/updates/BIOS.json

# Build bootc with bcachefs support from source
COPY patches/bootc /tmp/patches/bootc
RUN pacman -Syu --noconfirm make rust go-md2man git wget && \
    BOOTC_TAG=$(wget -qO- https://api.github.com/repos/bootc-dev/bootc/releases/latest | grep '"tag_name"' | cut -d'"' -f4) && \
    git clone --depth 1 --branch "$BOOTC_TAG" https://github.com/bootc-dev/bootc.git /tmp/bootc && \
    cd /tmp/bootc && \
    git apply /tmp/patches/bootc/0001-add-bcachefs-filesystem-support.patch && \
    cargo fetch --locked --target "$(rustc -vV | sed -n 's/host: //p')" && \
    make bin && \
    make DESTDIR=/ install-all && \
    cd / && rm -rf /tmp/bootc /tmp/bootc-target /tmp/patches && \
    pacman -R --noconfirm make rust go-md2man git && \
    pacman -Scc --noconfirm

# Necessary for general behavior expected by image-based systems
RUN printf "systemdsystemconfdir=/etc/systemd/system\nsystemdsystemunitdir=/usr/lib/systemd/system\n" | tee /usr/lib/dracut/dracut.conf.d/30-bootcrew-fix-bootc-module.conf && \
    printf 'reproducible=yes\nhostonly=no\ncompress=zstd\nadd_dracutmodules+=" ostree bootc "' | tee "/usr/lib/dracut/dracut.conf.d/30-bootcrew-bootc-container-build.conf" && \
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
