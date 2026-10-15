#!/usr/bin/env bash
set -Eeuo pipefail

: "${APP:="macOS"}"
: "${PLATFORM:="x64"}"
: "${SUPPORT:="https://github.com/dockur/macos"}"

: "${VGA:="vmware"}"
: "${SHUTDOWN:="Y"}"
: "${TIMEOUT:="105"}"
: "${DISK_TYPE:="blk"}"
: "${RAM_MINIMUM:="4G"}"
: "${DISK_MINIMUM:="32G"}"
: "${SOUND:="usb-audio"}"
: "${BOOT_MODE:="macos"}"

cd /run

. start.sh      # Startup hook
. utils.sh      # Load functions
. init.sh       # Initialize system
. memory.sh     # Check available memory
. server.sh     # Start webserver
. download.sh   # Load functions
. install.sh    # Get the OSX images
. disk.sh       # Initialize disks
. display.sh    # Initialize graphics
. audio.sh      # Initialize audio
. network.sh    # Initialize network
. boot.sh       # Configure boot
. cpu.sh        # Configure CPU model
. proc.sh       # Initialize processor
. power.sh      # Configure shutdown
. balloon.sh    # Initialize ballooning
. config.sh     # Configure arguments
. finish.sh     # Finish initialization

trap - ERR

cmd=(qemu-system-x86_64)
version=$("${cmd[@]}" --version | awk 'NR==1 { print $4 }')
info "Booting ${APP}${BOOT_DESC} using QEMU v$version..." && echo

pipe="$QEMU_DIR/qemu.pipe"
rm -f "$pipe" && mkfifo "$pipe"

sed -u \
  -e 's/\x1B\[[=0-9;]*[a-z]//gi' \
  -e 's/\x1B\x63//g' \
  -e 's/\x1B\[[=?]7l//g' \
  -e '/^$/d' \
  -e 's/\x44\x53\x73//g' \
  -e 's/failed to load Boot/skipped Boot/g' \
  <"$pipe" &

output=$!

if ! enabled "$SHUTDOWN"; then
  exec "${cmd[@]}" ${ARGS:+ $ARGS} >"$pipe" 2>&1
fi

if ! interactive; then
  "${cmd[@]}" ${ARGS:+ $ARGS} >"$pipe" 2>&1 &
else
  startConsole "$pipe"
  startQemu "${cmd[@]}" ${ARGS:+ $ARGS} >"$pipe" 2>&1
fi

pid=$!
rc=0

wait "$pid" || rc=$?
interactive && stopConsole
wait "$output" || :

# --- golden re-bake export (opt-in) ----------------------------------------
# When EXPORT_DISK_TO is set, the pod's OWN disk is compressed and uploaded
# right after the guest shuts down. This MUST run in the same pod that owns the
# disk (the PVC is node-local: a separate exporter pod may land elsewhere). The
# guest is baked via SSH BEFORE it is shut down, so this sees the final image.
if [ -n "${EXPORT_DISK_TO:-}" ]; then
  df="${DISK_FILE:-/storage/15/data.qcow2}"
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

[ -f "$QEMU_END" ] && exit "$rc"

sleep 1 & wait $!
finish "$rc"
