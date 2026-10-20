# easyworker macOS sandbox — self-owned runtime, pre-baked disk, boot only.
#
# No upstream sandbox image is referenced. The runtime is the generic
# qemux/qemu Debian base plus a vendored copy of the macOS boot scripts
# (vendor/run, taken once from the upstream project and kept here), the macOS
# firmware/identity assets, and the token/worker bridge. The upstream project's
# installer and its tooling are not part of this image at all.
#
# Only the boot path runs: the guest disk ships installed, so nothing downloads
# or installs macOS. `openCoreSignature()` still hashes /opencore.iso, /vmh.zip
# and /assets/config.plist, so those three stay even though the boot image is
# pre-built and reused.
ARG REGISTRY=docker.io/qemux
FROM ${REGISTRY}/qemu:750

# No proxy settings and no private mirrors: this file describes the image, not
# the build environment. Egress configuration belongs to whoever runs the build.

# --- OpenCore boot-image rebuild tools -------------------------------------
# The boot image is normally reused as-is, but a change to /assets/config.plist
# (e.g. csr-active-config to disable SIP for computer-use) changes
# openCoreSignature() and forces boot.sh to REBUILD the OpenCore image, which
# needs: xmlstarlet (plist edit/validate/select), xxd (ROM hex->binary),
# mtools (mformat/mcopy the EFI FAT image) and 7z (unpack opencore.iso /
# vmh.zip). The upstream installer image carries these; this boot-only image
# must add them.
RUN set -eux; \
    # Aliyun over HTTPS: reachable from a CI runner and from the cluster alike,
    # and https because some egress proxies refuse plain http:// and report it
    # misleadingly as a missing Release file.
    rm -f /etc/apt/sources.list.d/* /etc/apt/sources.list; \
    printf 'deb https://mirrors.aliyun.com/debian trixie main\n' > /etc/apt/sources.list; \
    printf 'deb https://mirrors.aliyun.com/debian trixie-updates main\n' >> /etc/apt/sources.list; \
    printf 'deb https://mirrors.aliyun.com/debian-security trixie-security main\n' >> /etc/apt/sources.list; \
    apt-get -o Acquire::Retries=10 update; \
    for i in 1 2 3 4 5 6; do \
      apt-get -o Acquire::Retries=10 install -y --no-install-recommends \
        xmlstarlet mtools file zip ffmpeg \
      && break || { echo "apt retry $i"; sleep 3; }; \
    done; \
    rm -rf /var/lib/apt/lists/*

# --- sandbox runtime -------------------------------------------------------
# The whole boot path is ONE script (sandbox.sh): identity + OpenCore + OVMF +
# network + audio + nginx + QEMU. vendor/run holds only the two helpers it
# calls: audio.py (FIFO->socket relay) and socket.sh (status websocket).
COPY --chmod=755 vendor/run/ /run/
COPY --chmod=755 sandbox.sh    /run/entry.sh
# Assets the boot path reads: the OpenCore config template, and the OpenCore
# and VMHide archives whose hashes feed the boot-image signature.
COPY --chmod=644 vendor/assets/config.plist /assets/config.plist
COPY --chmod=600 vendor/opencore/opencore.iso /opencore.iso
COPY --chmod=600 vendor/opencore/vmh.zip      /vmh.zip
COPY --chmod=644 vendor/version /etc/version

# --- pre-baked guest disk + boot state -------------------------------------
# The guest is already installed. base.dmg (the macOS recovery/install media) is
# deliberately not shipped: nothing installs macOS here, so it would be dead
# weight. The boot image, firmware and machine identity are pre-built and are
# reused as-is (their signature is unchanged, so boot.sh skips rebuilding them).
#
# The disk is ALWAYS embedded. There used to be an EMBED_DISK=0 mode that fetched
# it at run time from an in-cluster artifact store; that tied the image to one
# environment and made every start pay a 17 GiB download for immutable golden
# state.
#
# It lands in /opt/golden-disk, NOT /storage: /storage is where the writable
# volume is mounted, so a copy there would be hidden by the mount.
#
# The disk is written via a bind mount so it lands in EXACTLY ONE layer (a plain
# `COPY` of a multi-GB file that is then moved would store it TWICE).
RUN --mount=type=bind,source=disk/data.qcow2,target=/tmp/disk.qcow2 \
    mkdir -p /opt/golden-disk && cp /tmp/disk.qcow2 /opt/golden-disk/data.qcow2
COPY disk/support/boot.img   /storage/15/boot.img
COPY disk/support/boot.sig   /storage/15/boot.sig
COPY disk/support/macos.id   /storage/15/macos.id
COPY disk/support/macos.mac  /storage/15/macos.mac
COPY disk/support/macos.mlb  /storage/15/macos.mlb
COPY disk/support/macos.rom  /storage/15/macos.rom
COPY disk/support/macos.sn   /storage/15/macos.sn
COPY disk/support/macos.vars /storage/15/macos.vars
# Extra copies of the boot support files OUTSIDE /storage, so a PVC mounted at
# /storage (to persist ONLY the disk) does not hide them: start.sh copies these
# back into /storage/15 when the PVC shadows them. Boot state is image-owned.
COPY disk/support/boot.img   /opt/macboot/15/boot.img
COPY disk/support/boot.sig   /opt/macboot/15/boot.sig
COPY disk/support/macos.id   /opt/macboot/15/macos.id
COPY disk/support/macos.mac  /opt/macboot/15/macos.mac
COPY disk/support/macos.mlb  /opt/macboot/15/macos.mlb
COPY disk/support/macos.rom  /opt/macboot/15/macos.rom
COPY disk/support/macos.sn   /opt/macboot/15/macos.sn
COPY disk/support/macos.vars /opt/macboot/15/macos.vars

# --- easyworker + easystream (both boot-fetched by the guest) ------------
# The guest launcher downloads both on every boot (nginx :8090 /worker and
# /easystream): an upgrade is an image change, never a golden rebake. There is
# NO disk fallback — the container always serves them.
#
# Both binaries come from their GitHub releases (the source repos are the source
# of truth; the sandbox image just ships what they published).
ARG WORKER_VERSION=v0.1.0
ARG EASYSTREAM_VERSION=v0.1.0
ARG RELEASE_PROXY
ARG RELEASE_CACHEBUST
RUN set -eux; echo "release cachebust ${RELEASE_CACHEBUST}"; \
    mkdir -p /opt/easyworker; \
    for spec in \
      "easyworker|https://github.com/easydev-org/easyworker/releases/download/${WORKER_VERSION}/easyworker-darwin-amd64" \
      "easystream|https://github.com/easydev-org/easystream-macos/releases/download/${EASYSTREAM_VERSION}/easystream-darwin-amd64" ; do \
      name="${spec%%|*}"; url="${spec#*|}"; \
      curl -fsSL ${RELEASE_PROXY:+-x "${RELEASE_PROXY}"} -o "/opt/easyworker/${name}" "${url}"; \
    done; \
    chmod 755 /opt/easyworker/easyworker /opt/easyworker/easystream
# The REAL launch logic. The on-disk loader (/Users/docker/bootstrap.sh, the
# ONLY launch file on the golden disk) fetches this every boot, so ALL launch
# behaviour is an image change (no golden-disk rebake).
COPY --chmod=644 guest/oem.sh /opt/easyworker/oem.sh

# BlackHole: the virtual audio loopback. easystream captures the guest's system
# sound through it, so without this the sandbox has video but no audio.
#
# It is VENDORED IN THE REPO (guest/blackhole/) rather than downloaded at boot:
#   * the driver is a signed-less user-space HAL plugin (not a kext), so it needs
#     no SIP/kext-consent changes on the guest side;
#   * boot-fetching it from the image (nginx :8090/blackhole) keeps an upgrade an
#     image change, exactly like oem.sh and the worker, and means the macOS guest
#     never has to reach the internet;
#   * keeping it in the repo makes the build reproducible from a clone.
#
# Provenance (for auditing / rebuilding): ExistentialAudio/BlackHole v0.7.1,
# built with xcodebuild CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO
# CODE_SIGNING_ALLOWED=NO, sha256 of the tarball
# a98ec2773978f0e0687595fe9bb125ab6e1063a69c8a40ef44e8fabcb105d365.
COPY --chmod=644 guest/blackhole/BlackHole.driver-0.7.1.tgz /opt/easyworker/BlackHole.driver-0.7.1.tgz

# aggregate: builds the "easystream Audio" aggregate device (BlackHole looped
# through the QEMU sound card's clock) and makes it the guest's default output,
# so easystream only has to open the default output and read the loopback — it
# no longer needs to know about clocks, aggregates or device names.
#
# Swift, not C. The C version crashed inside CFDictionaryCreate while building the
# aggregate description and died before printing anything, so all the boot saw was
# a silent rc=139 — which under launchd's KeepAlive became an oem.sh restart every
# 10 s and a guest running nothing but sshd. Swift gets the CoreFoundation
# bridging right, and swiftc is only on macOS, so the binary is vendored next to
# its source.
#
# BOTH are committed: guest/audio/aggregate.swift is the readable implementation,
# guest/audio/aggregate-darwin-amd64 the x86_64 Mach-O it compiles to. Rebuild on
# any Mac with:  swiftc -O -o aggregate aggregate.swift
COPY --chmod=755 guest/audio/aggregate-darwin-amd64 /opt/easyworker/aggregate
COPY --chmod=644 guest/audio/aggregate.swift /opt/easyworker/aggregate.swift

# --- token/worker bridge (no sidecar) -------------------------------------
# nginx already includes conf.d/*.conf.
#
# NOTE: there is deliberately no /run/start.sh. This image's whole boot path is
# sandbox.sh (COPYed below as /run/entry.sh), and that is where the guest env and
# the /files payload tar are produced. A second "start.sh" used to be shipped here
# and was never sourced by anything, which is worse than useless: it made it look
# as though the env/tar step ran when it did not.
COPY --chmod=644 00-token.conf /etc/nginx/conf.d/00-token.conf
# Runtime disk materializer (fetches the artifact golden base + overlay); a
# no-op unless GOLDEN_DISK_URL is set.
COPY --chmod=755 golden-disk.sh /run/golden-disk.sh

# macOS 15 Sequoia, pre-baked disk => no installer phase.
# NOTE: Sequoia on this Ice Lake host deadlocks with 8 vCPUs; 4 is stable.
# WORKER_OS: empty (plain macos -> the macos xa11y driver).
ARG WORKER_OS=""
# Default golden disk (disk-less images): baked into ENV so the VM boots even
# when no GOLDEN_DISK_URL is injected; a pod env still overrides it.
ARG GOLDEN_DISK_URL=""
ENV VERSION=15 \
    CPU_CORES=4 \
    DISK_SIZE=128G \
    RAM_SIZE=16384M \
    SAMBA=N \
    DISK_FILE=/storage/15/data.qcow2 \
    USER_PORTS=48080 \
    WORKER_OS=${WORKER_OS} \
    GOLDEN_DISK_URL=${GOLDEN_DISK_URL}

# Display + resources. sandbox.sh owns the FULL QEMU command line (vmware VGA,
# nec-usb-xhci, isa-applesmc, the OpenCore + data disks, no VNC), so ARGUMENTS
# is an empty EXTRA-args slot here — the old `-device VGA` conflicted with
# sandbox.sh's `-vga vmware`.
#
# WIDTH/HEIGHT feed the OpenCore UEFI Output resolution and the OVMF VARS
# template selection. HEIGHT must be 1080 or 768 (the only templates the qemux
# base ships; see the symlinks below) or the boot dies with
# "UEFI boot file ... not found" (exit 44).
ENV WIDTH=1024 \
    HEIGHT=768 \
    ARGUMENTS=""

# boot.sh expects /usr/share/OVMF/OVMF_CODE.fd + OVMF_VARS[-WxH].fd, but the
# qemux base image only ships the 4M names (OVMF_CODE_4M.fd / OVMF_VARS_4M.fd).
# Without these links the very first boot of a fresh PVC dies with
# "UEFI boot file (/usr/share/OVMF/OVMF_CODE.fd) not found" (exit 44) — it only
# worked before because a previously generated .rom was still on the PVC.
RUN cd /usr/share/OVMF \
    && ln -sf OVMF_CODE_4M.fd OVMF_CODE.fd \
    && ln -sf OVMF_VARS_4M.fd OVMF_VARS.fd \
    && ln -sf OVMF_VARS_4M.fd OVMF_VARS-1920x1080.fd \
    && ln -sf OVMF_VARS_4M.fd OVMF_VARS-1024x768.fd \
    && ls -la /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_VARS*.fd

# The guest's easystream daemon streams the screen itself (over est/H.264), so
# the QEMU VNC display and the noVNC web client are dead weight: no VNC, no
# noVNC assets, no extra port.
ENV DISPLAY=none

# noVNC is only used by the VNC display we just turned off.
RUN rm -rf /usr/share/novnc /usr/share/novnc-* 2>/dev/null || true

VOLUME /storage
EXPOSE 22 48080 8090
ENTRYPOINT ["/usr/bin/tini", "-s", "/run/entry.sh"]
