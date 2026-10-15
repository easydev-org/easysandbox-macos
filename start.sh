#!/usr/bin/env bash
set -Eeuo pipefail

# AgentWorker: publish the pod-provided per-pod env the guest launcher fetches
# over nginx at http://host.lan:8090/env. The guest does NOT inherit the pod's
# env (the worker runs inside macOS), so anything the guest needs travels here:
#   WORKER_TOKEN  — pre-authorization (empty -> the guest's normal claim flow)
#   SANDBOX_PROXY — deployment-provided HTTP proxy (the guest has no direct
#                   internet, only the cluster; jobs like git/npm/go need it)
{
  printf 'WORKER_TOKEN=%s\n' "${WORKER_TOKEN:-}"
  printf 'SANDBOX_PROXY=%s\n' "${SANDBOX_PROXY:-${HTTP_PROXY:-}}"
} > /run/shm/env
chmod 644 /run/shm/env 2>/dev/null || true

# Boot support files (boot.img, macos.rom/vars/...) live in /storage/15 alongside
# the disk in the image. When a PVC is mounted at /storage (to persist ONLY the
# disk) it shadows the image copies, so restore them from the image's
# /opt/macboot copy. Boot state is image-owned, not disk state.
if [ -d /opt/macboot/15 ]; then
  mkdir -p /storage/15 2>/dev/null || true
  for f in boot.img boot.sig macos.id macos.mac macos.mlb macos.rom macos.sn macos.vars; do
    [ -s "/storage/15/$f" ] || cp -f "/opt/macboot/15/$f" "/storage/15/$f" 2>/dev/null || true
  done
fi

# Materialize the guest disk from the artifact-published golden base (overlay);
# a no-op when GOLDEN_DISK_URL is unset (image-embedded disk is used).
if [ -f /run/golden-disk.sh ]; then . /run/golden-disk.sh; fi

return 0
