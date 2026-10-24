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
  # Wait for the container to be genuinely up. "docker run -d" succeeding only
  # means the container was created; if its entrypoint dies immediately - which is
  # what an insufficient-memory or insufficient-disk check does - the container is
  # already gone by the time the next step looks, and the wait step then sits in
  # its heartbeat reporting nothing for an hour.
  local i
  for i in $(seq 1 30); do
    if ! docker ps --format "{{.Names}}" | grep -qx "$NAME"; then
      log "container is not running after ${i}s; its log:"
      docker logs "$NAME" 2>&1 | tail -40 || true
      log "docker inspect state:"
      docker inspect -f "{{.State.Status}} exit={{.State.ExitCode}} err={{.State.Error}}" "$NAME" 2>/dev/null || true
      return 1
    fi
    # Some images take a few seconds before they start logging, so require either
    # output or a few seconds of uptime before declaring it healthy.
    if [ -n "$(docker logs "$NAME" 2>&1 | head -1)" ] || [ "$i" -ge 10 ]; then
      break
    fi
    sleep 1
  done
  docker ps --filter "name=^$NAME$" --format "{{.Names}} {{.Status}}" || true
  first=$(docker logs "$NAME" 2>&1 | head -3 | tr "\n" " " || true)
  log "first container output: ${first}"
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

  # The state share is INSIDE the container, not on the runner.
  #
  # install.sh exports QEMU_DIR/installstate over 9p, and QEMU_DIR is /run/shm
  # (easysandbox-macos/sandbox.sh sets it, and it is the same layout the qemux
  # base image uses for qemu.pipe and the vnc socket). So the markers live at
  # /run/shm/installstate/bootstrap.done in the CONTAINER filesystem, which the
  # runner cannot see directly - an earlier version looked for
  # /run/installstate on the host and would never have found anything.
  #
  # Probing candidates inside the container costs one docker exec per attempt,
  # and only until the directory appears.
  find_state() {
    docker exec "$NAME" sh -c '
      for c in /run/shm/installstate /run/installstate /var/lib/dockur/installstate; do
        [ -d "$c" ] && { echo "$c"; exit 0; }
      done
      exit 1
    ' 2>/dev/null | tr -d "\r"
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
      # Read the markers through docker exec: they are on the container side of
      # the 9p export, not the runner side.
      if docker exec "$NAME" sh -c "test -f $state_dir/bootstrap.failed" 2>/dev/null; then
        log "bootstrap FAILED (guest wrote $state_dir/bootstrap.failed)"
        docker exec "$NAME" sh -c "ls -la $state_dir" 2>/dev/null || true
        docker logs "$NAME" 2>&1 | tail -80 || true
        return 1
      fi
      if docker exec "$NAME" sh -c "test -f $state_dir/bootstrap.done" 2>/dev/null; then
        log "bootstrap.done present after ${SECONDS}s - the guest is ready"
        # Record where the disk is WHILE the container still runs: docker exec
        # cannot inspect a stopped container, and extract runs after the stop.
        docker exec "$NAME" find /storage -maxdepth 2 -type f -size +1G \( -name "*.img" -o -name "*.qcow2" \) 2>/dev/null | tr -d "\r" > "$STORAGE/.disk-path" || true
        log "recorded disk path: $(head -1 "$STORAGE/.disk-path" 2>/dev/null)"
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
      # du over the whole tree, not a *.qcow2 glob with stat:
      #   * the extension is not guaranteed (the Windows bake writes data.img),
      #   * and stat on a sparse qcow2 reports the full DISK_SIZE from creation, so
      #     it never moves. This is the same pair of mistakes the Windows heartbeat
      #     made, and it is why macOS read disk=0MiB for 25 minutes.
      used=$(du -sm "$STORAGE" 2>/dev/null | cut -f1 || true)
      : "${used:=0}"
      # grep exits 1 when nothing matches, and under set -e a failing command
      # substitution aborts the script - so "no phase yet" would be fatal. Every
      # probe here is allowed to come back empty.
      phase=$(docker logs "$NAME" 2>&1 | grep -oE "installation state share mounted|unattended bootstrap preflight passed|selected /dev/[a-z0-9]+|starting online macOS installation|bootstrap installation succeeded" | tail -1 || true)
      log "${SECONDS}s  storage_used=${used}MiB  state=${state_dir:-not-yet}  phase=${phase:-early}"
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

  # The disk is in the bind mount, not hidden in the container: install.sh writes
  # it under \$STORAGE/\${VERSION} and the Windows bake showed the same layout with
  # /storage/data.img visible from the host. So convert it in place - no docker cp.
  #
  # docker cp was tried and is strictly worse: it does not preserve holes, so a
  # sparse 64 GiB image becomes 64 GiB of real I/O on the runner.
  #
  # The filename is still not worth guessing at, so stage_wait recorded the exact
  # path with find while the container was running (docker exec cannot inspect a
  # stopped one), and this reads it back.
  SRC=""
  recorded=$(head -1 "$STORAGE/.disk-path" 2>/dev/null || true)
  if [ -n "$recorded" ]; then
    cand="$STORAGE/$(basename "$recorded")"
    # macOS puts the disk one level down, so also try the version subdirectory.
    for c in "$cand" "$STORAGE/${VERSION}/$(basename "$recorded")"; do
      [ -f "$c" ] && { SRC="$c"; break; }
    done
  fi

  # Fall back to a sweep. qemu-img decides what is a disk, ISOs are skipped
  # because qemu-img reads them happily and would otherwise be chosen.
  if [ -z "$SRC" ]; then
    while IFS= read -r f; do
      case "$f" in *.iso|*.dmg) continue ;; esac
      if qemu-img info "$f" >/dev/null 2>&1; then SRC="$f"; break; fi
    done < <(find "$STORAGE" -type f -size +1G -printf "%s %p\n" 2>/dev/null | sort -rn | cut -d" " -f2-)
  fi

  if [ -z "$SRC" ]; then
    log "no disk found; storage tree:"
    find "$STORAGE" -maxdepth 3 -printf "%10s %p\n" 2>/dev/null | sort -rn | head -20 || true
    return 1
  fi

  log "converting $SRC"
  ls -la "$SRC"
  # -c compresses the stored clusters; read cost is one decompression per cluster,
  # acceptable for an image that becomes an overlay backing file. The macOS disk
  # is genuinely large (tens of GiB written), so this is where it matters most.
  qemu-img convert -O qcow2 -c "$SRC" "$OUT"
  log "converted: $(ls -la "$OUT")"
  qemu-img info "$OUT" | head -8
  du -h --apparent-size "$OUT" 2>/dev/null || ls -la "$OUT"
  du -h "$OUT" 2>/dev/null || true
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
