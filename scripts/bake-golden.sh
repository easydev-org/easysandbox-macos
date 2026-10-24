#!/usr/bin/env bash
# Bake a CLEAN macOS golden disk with dockur, in separately invocable stages.
#
# Same division of labour as bake-windows.sh: dockur PRODUCES the disk,
# easysandbox CONSUMES it. Nothing here drives the macOS installer.
#
# Stage split exists for the same reason as Windows: GitHub has no streaming
# log API (a running job returns 403/404 for its log blob), and the only live
# progress signal is the step list from /actions/jobs/{id}. A 60-minute install
# as its own step reads as "bake: wait for install -> in_progress".
#
#   prepare   check the host and claim KVM
#   start     create and start the container
#   wait      block until the unattended install reports success
#   extract   stop the guest and copy the qcow2 out
set -Eeuo pipefail

STAGE="${1:-all}"
VERSION="${VERSION:-14}"
ARCH="${ARCH:-x64}"
DISK_SIZE="${DISK_SIZE:-96G}"
RAM="${RAM:-8G}"
CPUS="${CPUS:-4}"
STORAGE="${STORAGE:?set STORAGE}"
OUT="${OUT:?set OUT}"
WAIT="${WAIT:-7200}"
NAME="${NAME:-macbake}"

log() { echo "[bake $(date -u +%H:%M:%S)] $*"; }

# x86_64 ONLY, and say so before doing any work. dockur/macos pins
# qemu-system-x86_64 and ships an X64-only OpenCore tree; there is no ARM64
# variant to fall back to. ARM macOS needs Apple Virtualization.framework on
# Apple hardware, which a Linux runner is not.
assert_supported() {
  case "$ARCH" in
    x64|x86_64|amd64) ;;
    *) log "macOS on $ARCH is not possible: dockur/macos is x86_64 only"
       log "(qemu-system-x86_64 + X64/EFI OpenCore); ARM needs Apple hardware."
       return 3 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) ;;
    *) log "host is $(uname -m); dockur/macos needs an x86_64 host"; return 3 ;;
  esac
  return 0
}

stage_prepare() {
  assert_supported
  log "macos $VERSION ($ARCH) -> $OUT"
  mkdir -p "$STORAGE" "$(dirname "$OUT")"
  if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
    echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666"' | sudo tee /etc/udev/rules.d/99-kvm4all.rules >/dev/null
    sudo udevadm control --reload-rules
    sudo udevadm trigger --name-match=kvm
  fi
  [ -e /dev/kvm ] || { log "NO /dev/kvm"; return 2; }
  ls -la /dev/kvm
  # Note the guest CPU profile this version will get. On AMD hosts dockur picks
  # Skylake-Client-v4 for 14+ and Haswell-noTSX for 13 and older (cpu.sh); if a
  # version fails to boot, that split is the first thing to suspect.
  log "prepare done; host=$(uname -m)"
}

stage_start() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  log "starting dockur/macos"
  docker run -d --name "$NAME" \
    --device=/dev/kvm \
    -e "VERSION=$VERSION" \
    -e "DISK_SIZE=$DISK_SIZE" \
    -e "RAM_SIZE=$RAM" \
    -e "CPU_CORES=$CPUS" \
    -v "$STORAGE:/storage" \
    dockurr/macos > /dev/null
  sleep 5
  docker ps --filter "name=^$NAME$" --format "{{.Names}} {{.Status}}" || true
  log "start done"
}

stage_wait() {
  # macOS has NO host-visible completion marker. Its progress lives inside the
  # guest at /Volumes/installstate/bootstrap.done, which the host cannot see, so
#"  the signal has to come from the container log. That line is emitted by
  # install/recovery/launch.sh right after the unattended bootstrap is in place.
  log "waiting for 'unattended bootstrap installed successfully'"
  deadline=$(( SECONDS + WAIT ))
  last_beat=0
  while (( SECONDS < deadline )); do
    if docker logs "$NAME" 2>&1 | grep -q "unattended bootstrap installed successfully"; then
      log "installer reported success after ${SECONDS}s"; return 0
    fi
    if ! docker ps --format "{{.Names}}" | grep -qx "$NAME"; then
      log "container exited before reporting success; tail:"
      docker logs "$NAME" 2>&1 | tail -60 || true
      return 1
    fi
    if (( SECONDS - last_beat >= 30 )); then
      last_beat=$SECONDS
      disk=$(find "$STORAGE" -name "*.qcow2" -type f -printf "%s\n" 2>/dev/null | sort -n | tail -1)
      : "${disk:=0}"
      tail_line=$(docker logs --tail 1 "$NAME" 2>&1 | tr -d "\r" | cut -c1-100 || true)
      log "${SECONDS}s  disk=$((disk/1048576))MiB  guest: $tail_line"
    fi
    sleep 30
  done
  log "TIMEOUT after ${WAIT}s; tail:"
  docker logs "$NAME" 2>&1 | tail -60 || true
  return 1
}

stage_extract() {
  log "stopping the guest"
  docker stop -t 240 "$NAME" >/dev/null 2>&1 || true
  # The disk is NOT at /storage/data.qcow2: install.sh rewrites
  # STORAGE="$STORAGE/${VERSION,,}" when the primary disk is absent, so it lands
  # under a version subdirectory. Search for the largest qcow2 instead of
  # guessing the name, and require it to be bigger than a fresh sparse file.
  log "locating the disk under $STORAGE"
  SRC=""
  while IFS= read -r f; do
    sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
    if [ "$sz" -gt $((1024*1024*1024)) ]; then SRC="$f"; break; fi
  done < <(find "$STORAGE" -name "*.qcow2" -type f 2>/dev/null)
  if [ -z "$SRC" ]; then log "no qcow2 larger than 1 GiB:"; find "$STORAGE" -maxdepth 2 -type f | head; return 1; fi
  log "using $SRC"
  ls -la "$SRC"
  qemu-img convert -O qcow2 "$SRC" "$OUT"
  qemu-img info "$OUT" | head -6
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  log "BAKED macos $VERSION ($ARCH) -> $OUT"
}

case "$STAGE" in
  prepare) stage_prepare ;;
  start)   stage_prepare; stage_start ;;
  wait)    stage_wait ;;
  extract) stage_extract ;;
  all)     stage_prepare; stage_start; stage_wait; stage_extract ;;
  *) echo "usage: $0 [prepare|start|wait|extract|all]"; exit 64 ;;
esac
