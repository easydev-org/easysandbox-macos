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
  # Completion is NOT a log line.
  #
  # install/recovery/launch.sh:204 prints "unattended bootstrap installed
  # successfully" and that is the moment the bootstrap HELPER is ready - the real
  # startosinstall only starts ~140 lines later (line 344), and after it finishes
  # the guest sits in "while :; do sleep 60; done" waiting for a reboot. Treating
  # that early message as done stops the container mid-install and yields a
  # half-written disk.
  #
  # The real signals are two marker files the guest writes into its state share:
  #
  #   bootstrap.done    the helper finished installing Setup Assistant + account
  #   bootstrap.failed  it did not
  #
  # That share is a 9p export of QEMU_DIR/installstate (install.sh:403,431), so
  # the markers appear on the HOST - the earlier comment claiming otherwise was
  # wrong, and it is why this step was checking the wrong thing.
  #
  # QEMU_DIR is in the qemux/qemu base image and is /run there (the image COPYs
  # its scripts to /run and runs /run/entry.sh from it). Rather than trust that
  # guess, locate the directory at run time: it is the one holding bootstrap.ready
  # or the exit markers. install.sh rm -rf's it on every container start, so it
  # only exists while an install is in flight, which also makes a stale marker
  # impossible.
  log "waiting for bootstrap.done in the guest state share"

  find_state() {
    # /run/installstate is where QEMU_DIR/installstate lands for the dockur
    # images. Fall back to a search so a base-image move does not silently
    # degrade this into "never completes".
    local c
    for c in /run/installstate /var/lib/dockur/installstate; do
      [ -d "$c" ] && { echo "$c"; return 0; }
    done
    c=$(docker exec "$NAME" sh -c 'ls -d /run/installstate 2>/dev/null' 2>/dev/null | tr -d '\r')
    [ -n "$c" ] && { echo "$c"; return 0; }
    return 1
  }

  deadline=$(( SECONDS + WAIT ))
  last_beat=0
  state_dir=""
  while (( SECONDS < deadline )); do
    # Note the explicit if: "X && Y" returns 1 when X is false, and with
    # set -e that kills the script on the second iteration when state_dir is
    # already set. The first version died exactly 30s in, which is one
    # heartbeat, for this reason.
    if [ -z "$state_dir" ]; then
      state_dir=$(find_state || true)
    fi

    if [ -n "$state_dir" ]; then
      if [ -f "$state_dir/bootstrap.failed" ]; then
        log "bootstrap FAILED (guest wrote bootstrap.failed)"
        docker logs "$NAME" 2>&1 | tail -80 || true
        return 1
      fi
      if [ -f "$state_dir/bootstrap.done" ]; then
        log "bootstrap.done present after ${SECONDS}s - the guest is ready"
        return 0
      fi
    fi

    if ! docker ps --format "{{.Names}}" | grep -qx "$NAME"; then
      log "container exited before bootstrap.done; tail:"
      docker logs "$NAME" 2>&1 | tail -80 || true
      return 1
    fi

    # Heartbeat. The disk size is the health signal a host can see: startosinstall
    # writes as it prepares, so a size stuck for many minutes is the one way to
    # tell "still working" from "hung". Report the stage we are in too, because
    # the two markers above only exist near the end.
    if (( SECONDS - last_beat >= 30 )); then
      last_beat=$SECONDS
      disk=$(find "$STORAGE" -name "*.qcow2" -type f -printf "%s\n" 2>/dev/null | sort -n | tail -1 || true)
      : "${disk:=0}"
      # grep exits 1 when nothing matches, and under set -e a failing command
      # substitution aborts the script - so "no phase yet" would be fatal. Every
      # probe here is allowed to come back empty.
      phase=$(docker logs "$NAME" 2>&1 | grep -oE "installation state share mounted|unattended bootstrap preflight passed|selected /dev/[a-z0-9]+|starting online macOS installation|bootstrap installation succeeded" | tail -1 || true)
      log "${SECONDS}s  disk=$((disk/1048576))MiB  state=${state_dir:-not-yet}  phase=${phase:-early}"
    fi
    sleep 30
  done

  log "TIMEOUT after ${WAIT}s"
  [ -n "$state_dir" ] && ls -la "$state_dir" || true
  docker logs "$NAME" 2>&1 | tail -80 || true
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
