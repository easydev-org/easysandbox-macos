#!/usr/bin/env bash
# sandbox.sh — the ENTIRE macOS-sandbox runtime, in one file.
#
# This replaces the 25 vendored boot scripts (vendor/run/*.sh) copied from the
# upstream dockur/macos project. That project can download a recovery image and
# install macOS from scratch; this sandbox only ever BOOTS a pre-baked disk, so
# the installer, the recovery downloader (aria2 + Apple's catalog), the answer
# machinery and the VNC/noVNC web client were dead weight.
#
# What it does, in order:
#   1. golden disk (golden-disk.sh, kept separate)
#   2. machine identity: SN / MLB / UUID / MAC (persisted on the PVC)
#   3. OpenCore: rebuild boot.img from /opencore.iso + /assets/config.plist
#      when the generated identity changes (the guest needs OpenCore to boot)
#   4. firmware: OVMF code/vars -> /storage/15/macos.{rom,vars}
#   5. network : bridge docker + tap qemu + dnsmasq + NAT
#   6. audio   : FIFO + audio.py relay (AUDIO=Y)
#   7. servers : nginx :8090 + status websocket
#   8. QEMU    : the exact device set macOS needs (vmware VGA, nec-usb-xhci,
#                isa-applesmc, virtio-blk OpenCore + data disks, no VNC)
#
# macOS-specific details preserved from the upstream:
#   * CPU: an Intel-compatible profile (Skylake-Client-v4 / Haswell-noTSX) with
#     features mirrored from the host, because macOS rejects a raw host CPU on
#     AMD or under TCG (cpu.sh).
#   * SMP: macOS only accepts a few socket/core topologies (cpu.sh).
#   * OpenCore: boot.img is regenerated whenever the identity changes
#     (boot.sh). Requires xmlstarlet/xxd/mtools/7z.
set -Eeuo pipefail

# ── configuration (env overrides everything) ────────────────────────────────
APP="${APP:-macOS}"
PROCESS="${PROCESS:-macos}"
VERSION="${VERSION:-15}"
STORAGE="${STORAGE:-/storage}"
# Per-version state dir (/storage/15). This is where the guest disk, the
# OpenCore image, the firmware and the machine-identity files live — the same
# layout the vendored scripts used (stateFile() namespaces under $STORAGE).
VMDIR="$STORAGE/$VERSION"
QEMU_DIR="${QEMU_DIR:-/run/shm}"
DISK_FILE="${DISK_FILE:-$VMDIR/data.qcow2}"
RAM_SIZE="${RAM_SIZE:-16384M}"
CPU_CORES="${CPU_CORES:-4}"
MAC="${MAC:-}"
MTU="${MTU:-}"
UPLINK_DEV="${UPLINK_DEV:-eth0}"
WIDTH="${WIDTH:-1024}"
HEIGHT="${HEIGHT:-768}"
MODEL="${MODEL:-iMacPro1,1}"
SN="${SN:-}"
MLB="${MLB:-}"
UUID="${UUID:-}"

BRIDGE="${BRIDGE:-docker}"
TAP="${TAP:-qemu}"
BRIDGE_IP="${BRIDGE_IP:-172.30.0.1}"
GUEST_IP="${GUEST_IP:-172.30.0.2}"
SYSTEM_IP="${SYSTEM_IP:-172.30.0.254}"
MASK="${MASK:-255.255.255.0}"
PREFIX="${PREFIX:-24}"

AUDIO="${AUDIO:-N}"
SOUND="${SOUND:-usb-audio}"
ARGUMENTS="${ARGUMENTS:-}"
LOGO="${LOGO:-Y}"
DEBUG="${DEBUG:-N}"
CLEAR="${CLEAR:-N}"
PICKER="${PICKER:-N}"

OVMF=/usr/share/OVMF
mkdir -p "$STORAGE" "$QEMU_DIR" "$VMDIR"

log()  { printf '\033[1;34m❯\033[0m %s\n' "$*"; }
warn() { printf '\033[1;31m❯ Warning:\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m❯ ERROR:\033[0m %s\n' "$*" >&2; }
enabled() { case "${1^^}" in Y|YES|TRUE|1|ON) return 0;; *) return 1;; esac; }
disabled() { ! enabled "$1"; }

# ── 1. golden disk ─────────────────────────────────────────────────────────
if [ -f /run/golden-disk.sh ]; then . /run/golden-disk.sh; fi
if [ ! -s "$DISK_FILE" ]; then
  err "No guest disk at $DISK_FILE (this image boots a pre-baked disk and never installs macOS)."
  exit 69
fi

# The guest does NOT inherit the pod's env, so the few per-pod values it needs
# (the pre-auth token + the deployment HTTP proxy) are published as KEY=VALUE
# lines that nginx serves at :8090/env (00-token.conf). Without this the guest
# launcher gets a 404 and never fetches the worker/easystream binaries.
{
  printf 'WORKER_TOKEN=%s\n' "${WORKER_TOKEN:-}"
  printf 'SANDBOX_PROXY=%s\n' "${SANDBOX_PROXY:-${HTTP_PROXY:-}}"
} > "$QEMU_DIR/env"
chmod 644 "$QEMU_DIR/env" 2>/dev/null || true

# ── host detection ─────────────────────────────────────────────────────────
is_amd_cpu() {
  local v; v=$(awk -F': *' '/^vendor_id/{print $2; exit}' /proc/cpuinfo)
  [ "$v" = "AuthenticAMD" ]
}
has_flag() { grep -m1 '^flags' /proc/cpuinfo | grep -qw -- "$1"; }

# MTU: inherit the node's uplink MTU; jumbo only when asked.
detect_mtu() {
  local dev_mtu=""
  if [ -r "/sys/class/net/$UPLINK_DEV/mtu" ]; then dev_mtu=$(< "/sys/class/net/$UPLINK_DEV/mtu"); fi
  if [ -z "${MTU:-}" ]; then MTU="${dev_mtu:-1500}"
  elif [ "$MTU" -gt 1500 ] 2>/dev/null; then MTU=1500
  fi
  if [ "$MTU" = "0" ]; then MTU=1500; fi
  return 0
}

# ── 2. machine identity (persisted; macOS ties the install to it) ──────────
# File names match the vendored layout ($VMDIR/<process>.<field>) so an
# existing sandbox keeps its identity: <process>.sn/.mlb/.mac and <process>.id
# (the UUID). Regenerating them would invalidate the OpenCore config AND the
# iCloud/iMessage state on the guest disk.
gen_hex()  { local n="$1" s=""; for ((i=0;i<n;i++)); do s+=$(printf '%x' $((RANDOM%16))); done; printf '%s' "${s^^}"; }
gen_uuid() { printf '%s-%s-%s-%s-%s' "$(gen_hex 8)" "$(gen_hex 4)" "$(gen_hex 4)" "$(gen_hex 4)" "$(gen_hex 12)"; }
gen_mac()  { printf '00:16:CB:%s:%s:%s' "$(gen_hex 2)" "$(gen_hex 2)" "$(gen_hex 2)"; }
read_or_gen() {  # file, generator args...
  local f="$1"; shift
  [ -s "$f" ] || "$@" > "$f"
  cat "$f"
}
setup_identity() {
  SN="${SN:-$(read_or_gen "$VMDIR/$PROCESS.sn" gen_hex 12)}"
  MLB="${MLB:-$(read_or_gen "$VMDIR/$PROCESS.mlb" gen_hex 17)}"
  UUID="${UUID:-$(read_or_gen "$VMDIR/$PROCESS.id" gen_uuid)}"
  MAC="${MAC:-$(read_or_gen "$VMDIR/$PROCESS.mac" gen_mac)}"
}

# ── 3. OpenCore boot image ─────────────────────────────────────────────────
# The guest boots through OpenCore, whose config carries the machine identity.
# Rebuild boot.img only when the identity (or a source file) changes, so a
# stable sandbox reuses its PVC copy.
opencore_signature() {
  { echo "MODEL=$MODEL"; echo "SN=$SN"; echo "MLB=$MLB"; echo "UUID=$UUID"
    echo "MAC=$MAC"; echo "WIDTH=$WIDTH"; echo "HEIGHT=$HEIGHT"; echo "PICKER=$PICKER"
    sha256sum /opencore.iso /assets/config.plist /vmh.zip 2>/dev/null; } | sha256sum | awk '{print $1}'
}
build_opencore() {
  local target="$VMDIR/boot.img" sigf="$VMDIR/boot.sig"
  local current previous=""
  current=$(opencore_signature)
  if [ -s "$sigf" ]; then previous=$(cat "$sigf"); fi
  if [ -s "$target" ] && [ "$previous" = "$current" ]; then
    log "OpenCore boot image is up to date"
    return 0
  fi
  if [ -s "$target" ]; then log "Rebuilding OpenCore boot image..."; else log "Building OpenCore boot image..."; fi

  local OUT=/tmp/oc; rm -rf "$OUT"; mkdir -p "$OUT"
  [ -s /opencore.iso ] || { err "missing /opencore.iso"; exit 10; }
  7z x /opencore.iso -o"$OUT" >/dev/null || { err "Failed to extract opencore.iso"; exit 11; }
  local CFG; CFG="$(find "$OUT" -type f -path '*/EFI/OC/config.plist' -print -quit)"
  if [ -z "$CFG" ]; then err "no config.plist in opencore.iso"; exit 12; fi
  local EFI_DIR="${CFG%/OC/config.plist}"

  cp /assets/config.plist "$CFG"
  # ROM is six raw MAC bytes as plist <data> (base64), not a string.
  local rom; rom=$(printf '%s' "${MAC//[^[:alnum:]]/}" | tr 'A-Z' 'a-z' | xxd -r -p | base64)
  local generic="/plist/dict/key[.='PlatformInfo']/following-sibling::dict[1]/key[.='Generic']/following-sibling::dict[1]"
  local output="/plist/dict/key[.='UEFI']/following-sibling::dict[1]/key[.='Output']/following-sibling::dict[1]"
  xmlstarlet ed -P -L \
    -u "$generic/key[.='ROM']/following-sibling::data[1]" -v "$rom" \
    -u "$generic/key[.='SystemProductName']/following-sibling::string[1]" -v "$MODEL" \
    -u "$generic/key[.='SystemSerialNumber']/following-sibling::string[1]" -v "$SN" \
    -u "$generic/key[.='MLB']/following-sibling::string[1]" -v "$MLB" \
    -u "$generic/key[.='SystemUUID']/following-sibling::string[1]" -v "$UUID" \
    -u "$output/key[.='Resolution']/following-sibling::string[1]" -v "${WIDTH}x${HEIGHT}@32" \
    "$CFG"
  if enabled "$PICKER"; then
    local boot="/plist/dict/key[.='Misc']/following-sibling::dict[1]/key[.='Boot']/following-sibling::dict[1]"
    xmlstarlet ed -P -L \
      -r "$boot/key[.='ShowPicker']/following-sibling::*[1]" -v true \
      -r "$boot/key[.='HideAuxiliary']/following-sibling::*[1]" -v false \
      -u "$boot/key[.='Timeout']/following-sibling::integer[1]" -v 60 \
      -u "$boot/key[.='PickerMode']/following-sibling::string[1]" -v Builtin "$CFG"
  fi

  # VMHide kext (hides the hypervisor from macOS).
  7z x /vmh.zip -o"$OUT/kext" >/dev/null || { err "Failed to extract vmh.zip"; exit 11; }
  mv "$OUT/kext/VMHide.kext" "$EFI_DIR/OC/Kexts/"
  rm -rf "$OUT/kext"

  # Build a fixed-size GPT disk with one FAT32 ESP, no loop device.
  local size_mb=256 cluster=4 start_sector=2048 sector=512 first_lba=34
  local img=/tmp/OpenCore.img
  local image_size=$(( size_mb*1024*1024 ))
  local part_off=$(( start_sector*sector ))
  local usable=$(( image_size-(first_lba*sector) ))
  local last_lba=$(( usable/sector ))
  local count=$(( last_lba-(start_sector-1) ))
  truncate -s "$image_size" "$img" || { err "truncate failed"; exit 11; }
  {
    echo "label: gpt"; echo "label-id: 1ACB1E00-3B8F-4B2A-86A4-D99ED21DCAEB"
    echo "device: OpenCore.img"; echo "unit: sectors"; echo "first-lba: $first_lba"
    echo "last-lba: $last_lba"; echo "sector-size: $sector"; echo
    echo "OpenCore.img1 : start=$start_sector, size=$count, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, uuid=05157F6E-0AE8-4D1A-BEA5-AC172453D02C, name=\"primary\""
  } > /tmp/oc.fdisk
  sfdisk -q "$img" < /tmp/oc.fdisk || { err "sfdisk failed"; exit 11; }
  echo "drive c: file=\"$img\" partition=0 offset=$part_off" > /etc/mtools.conf
  mformat -F -M "$sector" -c "$cluster" -T "$count" -v EFI C: || { err "mformat failed"; exit 11; }
  mcopy -bspmQ "$EFI_DIR" C: || { err "mcopy failed"; exit 11; }
  rm -rf "$OUT"

  mv -f "$img" "$target" || { err "Failed to publish $target"; exit 11; }
  printf '%s' "$current" > "$sigf"
  log "OpenCore boot image ready ($MODEL, serial $SN)"
}

# ── 4. firmware: OVMF code + vars ──────────────────────────────────────────
prepare_firmware() {
  local rom="$OVMF/OVMF_CODE.fd"
  local vars
  case "$HEIGHT" in
    1080) vars="$OVMF/OVMF_VARS-1920x1080.fd" ;;
    768)  vars="$OVMF/OVMF_VARS-1024x768.fd" ;;
    *)    vars="$OVMF/OVMF_VARS.fd" ;;
  esac
  [ -s "$rom" ]  || { err "UEFI boot file ($rom) not found"; exit 44; }
  [ -s "$vars" ] || { err "UEFI vars file ($vars) not found"; exit 45; }
  if enabled "$CLEAR"; then rm -f "$VMDIR/$PROCESS.rom" "$VMDIR/$PROCESS.vars"; fi
  # Rebuild the ROM (cheap) so a stale PVC copy never wins; logo patch is optional.
  rm -f "$VMDIR/$PROCESS.rom.tmp"
  local logo="$QEMU_DIR/img/${PROCESS}.bmp"
  [ -s "$logo" ] || logo="$QEMU_DIR/img/qemu.bmp"
  if enabled "$LOGO" && [ -s "$logo" ] && [ -x /run/boot-logo ]; then
    /run/boot-logo "$logo" "$rom" --output "$VMDIR/$PROCESS.rom.tmp" -q 2>/dev/null || rm -f "$VMDIR/$PROCESS.rom.tmp"
  fi
  [ -s "$VMDIR/$PROCESS.rom.tmp" ] || cp "$rom" "$VMDIR/$PROCESS.rom.tmp"
  mv -f "$VMDIR/$PROCESS.rom.tmp" "$VMDIR/$PROCESS.rom"
  # The writable NVRAM store carries OpenCore boot state, so only seed it once.
  [ -s "$VMDIR/$PROCESS.vars" ] || cp "$vars" "$VMDIR/$PROCESS.vars"
}

# ── 5. network: bridge + tap + dnsmasq + NAT ───────────────────────────────
setup_network() {
  enabled "${NETWORK:-Y}" || return 0
  log "Initializing network..."
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  ip link add dev "$BRIDGE" type bridge 2>/dev/null || true
  ip link set "$BRIDGE" mtu "$MTU" 2>/dev/null || true
  ip address add "$BRIDGE_IP/$PREFIX" dev "$BRIDGE" 2>/dev/null || true
  ip link set "$BRIDGE" up
  sysctl -w "net.ipv6.conf.$BRIDGE.disable_ipv6=1" >/dev/null 2>&1 || true
  ip tuntap add dev "$TAP" mode tap 2>/dev/null || true
  ip link set "$TAP" mtu "$MTU" 2>/dev/null || true
  ip link set dev "$TAP" up promisc on
  sysctl -w "net.ipv6.conf.$TAP.disable_ipv6=1" >/dev/null 2>&1 || true
  ip link set dev "$TAP" master "$BRIDGE"

  rm -f /var/run/dnsmasq.pid /etc/resolv.dnsmasq
  /usr/sbin/dnsmasq \
    --dhcp-authoritative --dhcp-range="$GUEST_IP,$GUEST_IP" \
    --dhcp-host="$MAC,,$GUEST_IP,$APP,1h" \
    --dhcp-option=option:netmask,"$MASK" --dhcp-option=option:router,"$BRIDGE_IP" \
    --dhcp-option=option:dns-server,"$BRIDGE_IP" --dhcp-option=option:mtu,"$MTU" \
    --interface="$BRIDGE" --bind-interfaces --no-ping \
    --address=/host.lan/$BRIDGE_IP --address=/system.lan/$SYSTEM_IP \
    --filter-AAAA --pid-file=/var/run/dnsmasq.pid --log-facility=/var/log/dnsmasq.log

  iptables -t nat -N QEMU_DNAT 2>/dev/null || true
  iptables -t nat -F QEMU_DNAT
  iptables -t nat -C PREROUTING -m addrtype --dst-type LOCAL -j QEMU_DNAT 2>/dev/null \
    || iptables -t nat -A PREROUTING ! -i "$BRIDGE" -m addrtype --dst-type LOCAL -m comment --comment QEMU_DNAT -j QEMU_DNAT
  iptables -t nat -C POSTROUTING -s "$BRIDGE_IP/$PREFIX" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s "$BRIDGE_IP/$PREFIX" ! -d "$BRIDGE_IP/$PREFIX" ! -o "$BRIDGE" -m comment --comment QEMU_DNAT -j MASQUERADE
  iptables -t nat -A QEMU_DNAT -m comment --comment QEMU_DNAT -j DNAT --to-destination "$GUEST_IP"
  iptables -t filter -C FORWARD -s "$BRIDGE_IP/$PREFIX" -j ACCEPT 2>/dev/null \
    || iptables -t filter -A FORWARD -s "$BRIDGE_IP/$PREFIX" -i "$BRIDGE" ! -o "$BRIDGE" -j ACCEPT
  iptables -t filter -C FORWARD -d "$GUEST_IP/32" -j ACCEPT 2>/dev/null \
    || iptables -t filter -A FORWARD -d "$GUEST_IP/32" ! -i "$BRIDGE" -o "$BRIDGE" -j ACCEPT
}

# ── 6. audio: FIFO + relay ─────────────────────────────────────────────────
AUDIO_OPTS=""
setup_audio() {
  enabled "$AUDIO" || return 0
  local fifo="$QEMU_DIR/audio.fifo" sock="$QEMU_DIR/audio.sock"
  rm -f "$fifo" "$sock" /var/log/audio.log
  mkfifo -m 0600 "$fifo" || { warn "Failed to create audio FIFO"; AUDIO="N"; return 0; }
  python3 /run/audio.py "$fifo" "$sock" > /var/log/audio.log 2>&1 &
  echo $! > "$QEMU_DIR/audio.pid"
  local i; for i in $(seq 1 40); do [ -s /var/log/audio.log ] && break; sleep 0.25; done
  websocketd --unixsocket="$QEMU_DIR/audio-ws.sock" --binary=true nc -U "$sock" >/dev/null 2>&1 &
  echo $! > "$QEMU_DIR/audio-ws.pid"
  AUDIO_OPTS=" -audiodev wav,id=snd,path=$fifo,out.frequency=48000,out.channels=2,out.format=s16 -device $SOUND,audiodev=snd"
}

# ── 7. nginx + status ws ───────────────────────────────────────────────────
start_servers() {
  nginx -e stderr || warn "nginx failed to start"
  websocketd --unixsocket="$QEMU_DIR/status-ws.sock" /run/socket.sh >/dev/null 2>&1 &
  echo $! > "$QEMU_DIR/status-ws.pid"
}

# ── 8. CPU profile (macOS needs an Intel-compatible model) ─────────────────
# macOS refuses a raw host CPU on AMD / under TCG, and is picky about SMP.
DEFAULT_FLAGS="vendor=GenuineIntel,vmx=off,vmware-cpuid-freq=on,-pdpe1gb"
cpu_profile() {
  local amd=0
  is_amd_cpu && amd=1
  disabled "${KVM:-Y}" && amd=1        # TCG also needs the explicit profile

  if [ "$amd" = "1" ]; then
    case "${VERSION,,}" in
      10*|11*|12*|13*|catalina|bigsur|big-sur|monterey|ventura) CPU_MODEL="Haswell-noTSX" ;;
      *) CPU_MODEL="Skylake-Client-v4"
         if has_flag spec-ctrl && enabled "${KVM:-Y}"; then DEFAULT_FLAGS+=",+spec-ctrl"; else DEFAULT_FLAGS+=",-spec-ctrl"; fi ;;
    esac
    if disabled "${KVM:-Y}"; then
      DEFAULT_FLAGS+=",-pcid,-invpcid,-tsc-deadline,-xsavec,-xsaves"
    else
      local f; for f in pcid invpcid tsc-deadline xsavec xsaves; do
        has_flag "$f" && DEFAULT_FLAGS+=",+$f" || DEFAULT_FLAGS+=",-$f"
      done
    fi
    DEFAULT_FLAGS+=",+ssse3,+sse4.2,+popcnt,+avx,+avx2,+aes,+fma,+bmi1,+bmi2,+smep,+xsave,+xsaveopt,+xgetbv1,+movbe,+rdrand,check"
  else
    CPU_MODEL="${CPU_MODEL:-Skylake-Client-v4}"
  fi
  has_flag avx2 || warn "This processor does not support AVX2; macOS newer than 13 needs Haswell/Zen or newer."
}

smp_topology() {
  case "$CPU_CORES" in
    1|2|4|8)            echo "$CPU_CORES,sockets=1,dies=1,cores=$CPU_CORES,threads=1" ;;
    6|7)                echo "$CPU_CORES,sockets=3,dies=1,cores=2,threads=1" ;;
    10|11)              echo "$CPU_CORES,sockets=5,dies=1,cores=2,threads=1" ;;
    12|13)              echo "$CPU_CORES,sockets=3,dies=1,cores=4,threads=1" ;;
    14|15)              echo "$CPU_CORES,sockets=7,dies=1,cores=2,threads=1" ;;
    16|24|32|64)        echo "$CPU_CORES,sockets=1,dies=1,cores=$CPU_CORES,threads=1" ;;
    *)                  echo "$CPU_CORES,sockets=1,dies=1,cores=$CPU_CORES,threads=1" ;;
  esac
}

# ── 9. QEMU ────────────────────────────────────────────────────────────────
build_qemu_args() {
  # RAM: clamp to the pod's cgroup limit (never the node's /proc/meminfo).
  local ram_mb
  case "$RAM_SIZE" in
    *G) ram_mb=$(( ${RAM_SIZE%G} * 1024 )) ;;
    *M) ram_mb=${RAM_SIZE%M} ;;
    *)  ram_mb=${RAM_SIZE%M} ;;
  esac
  local limit_b limit_mb
  limit_b=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo 0)
  case "$limit_b" in ''|max|*[!0-9]*) limit_mb=0;; *) limit_mb=$(( limit_b / 1048576 ));; esac
  if [ "$limit_mb" -gt 0 ]; then
    local want=$(( limit_mb - 1536 )); [ "$want" -lt 1024 ] && want=1024
    if [ "$ram_mb" -gt "$want" ]; then warn "RAM_SIZE ${RAM_SIZE} exceeds the pod limit (${limit_mb}MB); using ${want}MB."; ram_mb=$want; fi
  fi

  local osk; osk=$(echo "bheuneqjbexolgurfrjbeqfthneqrqcyrnfrqbagfgrny(p)NccyrPbzchgreVap" | tr 'A-Za-z' 'N-ZA-Mn-za-m')

  ARGS="-nodefaults"
  ARGS+=" -machine type=q35,smm=off,graphics=off,vmport=off,dump-guest-core=off,hpet=off,accel=kvm"
  ARGS+=" -enable-kvm"
  ARGS+=" -global kvm-pit.lost_tick_policy=discard"
  ARGS+=" -cpu ${CPU_MODEL},kvm=on,l3-cache=on,+hypervisor,+invtsc,${DEFAULT_FLAGS}"
  ARGS+=" -smp $(smp_topology)"
  ARGS+=" -m ${ram_mb}M"
  ARGS+=" -name $APP,process=$PROCESS"
  ARGS+=" -uuid $UUID"
  ARGS+=" -pidfile $QEMU_DIR/qemu.pid"
  # DISPLAY=none: the guest streams its own screen over est/H.264.
  ARGS+=" -display none"
  ARGS+=" -vga vmware"
  ARGS+=" -monitor unix:$QEMU_DIR/monitor.sock,server=on,wait=off,nodelay=on"
  ARGS+=" -serial mon:stdio"
  ARGS+=" -device nec-usb-xhci,id=xhci"
  ARGS+=" -device usb-kbd,bus=xhci.0"
  ARGS+=" -global nec-usb-xhci.msi=off"
  ARGS+=" -device usb-tablet"
  ARGS+=" -netdev tap,id=hostnet0,ifname=$TAP,script=no,downscript=no"
  ARGS+=" -device virtio-net-pci,id=net0,netdev=hostnet0,romfile=,mac=$MAC,host_mtu=$MTU"
  ARGS+=" -drive file=$DISK_FILE,id=data3,format=qcow2,cache=none,aio=native,discard=unmap,detect-zeroes=on,if=none"
  ARGS+=" -device virtio-blk-pci,drive=data3,bus=pcie.0,addr=0xa,iothread=io2,bootindex=3"
  ARGS+=" -object iothread,id=io2"
  ARGS+=" -device virtio-blk-pci,drive=OpenCore,bus=pcie.0,addr=0x5,bootindex=9"
  ARGS+=" -drive file=$VMDIR/boot.img,id=OpenCore,format=raw,cache=unsafe,readonly=on,if=none"
  ARGS+=" -rtc base=utc"
  ARGS+=" -smbios type=2"
  ARGS+=" -global ICH9-LPC.disable_s3=1"
  ARGS+=" -global ICH9-LPC.disable_s4=1"
  ARGS+=" -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off"
  ARGS+=" -device isa-applesmc,osk=$osk"
  ARGS+=" -drive if=pflash,format=raw,readonly=on,file=$VMDIR/$PROCESS.rom"
  ARGS+=" -drive if=pflash,format=raw,file=$VMDIR/$PROCESS.vars"
  ARGS+=" -object rng-random,id=objrng0,filename=/dev/urandom"
  ARGS+=" -device virtio-rng-pci,rng=objrng0,id=rng0,bus=pcie.0"
  ARGS+=" -device virtio-balloon-pci,id=balloon0,bus=pcie.0"
  ARGS+="$AUDIO_OPTS"
  ARGS+=" -fw_cfg name=opt/org.tianocore/UninstallMemAttrProtocol,string=y"
  if [ -n "$ARGUMENTS" ]; then ARGS+=" $ARGUMENTS"; fi
  return 0
}

# ── run ────────────────────────────────────────────────────────────────────
_ncores=$(grep -c '^processor' /proc/cpuinfo)
if [ "$CPU_CORES" -gt "$_ncores" ] 2>/dev/null; then CPU_CORES="$_ncores"; fi
detect_mtu
setup_identity
build_opencore
prepare_firmware
setup_network
setup_audio
start_servers
cpu_profile
build_qemu_args

log "Starting $APP..."
log "Booting $APP using QEMU $(qemu-system-x86_64 --version | awk 'NR==1{print $4}')..."

pipe="$QEMU_DIR/qemu.pipe"
rm -f "$pipe"; mkfifo "$pipe"
# Strip the ANSI/EFI noise the upstream filtered, so the container log is useful.
sed -u \
  -e 's/\x1B\[[=0-9;]*[a-z]//gi' -e 's/\x1B\x63//g' -e 's/\x1B\[[=?]7l//g' \
  -e '/^$/d' -e 's/\x44\x53\x73//g' -e 's/failed to load Boot/skipped Boot/g' \
  <"$pipe" &
output=$!

qemu-system-x86_64 $ARGS > "$pipe" 2>&1 &
pid=$!

cleanup() {
  kill "$pid" 2>/dev/null || true
  kill "$output" 2>/dev/null || true
  for f in "$QEMU_DIR"/audio.pid "$QEMU_DIR"/audio-ws.pid "$QEMU_DIR"/status-ws.pid; do
    if [ -f "$f" ]; then kill "$(cat "$f")" 2>/dev/null || true; fi
  done
  if [ -f /var/run/dnsmasq.pid ]; then kill "$(cat /var/run/dnsmasq.pid)" 2>/dev/null || true; fi
}
trap cleanup TERM INT

rc=0
wait "$pid" || rc=$?
cleanup

# --- golden re-bake export (opt-in) ----------------------------------------
# When EXPORT_DISK_TO is set, the pod's OWN disk is compressed and uploaded
# right after the guest shuts down. This MUST run in the same pod that owns the
# disk (the PVC is node-local: a separate exporter pod may land elsewhere).
if [ -n "${EXPORT_DISK_TO:-}" ]; then
  df="$DISK_FILE"
  if [ -s "$df" ]; then
    echo "[export] compressing $df"
    qemu-img convert -O qcow2 -c -o compression_type=zstd,cluster_size=1M "$df" "$df.zst" \
      && mv -f "$df.zst" "$df" || echo "[export] compress failed"
    echo "[export] uploading $df -> $EXPORT_DISK_TO"
    curl -fS -T "$df" -H "Authorization: Bearer ${ARTIFACT_TOKEN:-dev-artifact-token}" \
      -w '[export] PUT http=%{http_code} size=%{size_upload}\n' "$EXPORT_DISK_TO" \
      || echo "[export] upload failed"
  else
    echo "[export] no disk at $df"
  fi
fi
exit "$rc"
