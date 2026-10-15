#!/bin/bash
# macOS guest LOADER — the ONLY launch file baked into the golden disk.
#
# Its single job is to pull the real launch script from the container and run
# it, so ANY launch change is an image change (never a golden rebake):
#
#   http://host.lan:8090/oem.sh  ->  /Users/docker/oem.sh
#
# It is run in BOTH contexts (same script): as root by the LaunchDaemon, and as
# docker by the Aqua LaunchAgent.
set -uo pipefail

WROOT=/Users/docker
BOOT="$WROOT/oem.sh"
DL="$WROOT/oem.sh.dl"
WS="$WROOT/workspace"
LOG="$WS/bootstrap.log"

# One workspace dir, owned by docker (same as Windows' C:\Users\Docker\workspace):
# the worker's DB/files and every log live here.
mkdir -p "$WS" 2>/dev/null || true
chown docker:staff "$WS" 2>/dev/null || true

for _ in $(seq 1 60); do
  curl -s -m 30 -o "$DL" http://host.lan:8090/oem.sh 2>/dev/null || true
  if [ "$(stat -f%z "$DL" 2>/dev/null || echo 0)" -gt 100 ]; then
    chmod 755 "$DL"
    mv -f "$DL" "$BOOT" 2>/dev/null || cp -f "$DL" "$BOOT"
    break
  fi
  rm -f "$DL" 2>/dev/null || true
  sleep 2
done

if [ -x "$BOOT" ]; then
  exec "$BOOT"
else
  echo "$(date) bootstrap fetch FAILED" >>"$LOG" 2>/dev/null || true
  exit 1
fi
