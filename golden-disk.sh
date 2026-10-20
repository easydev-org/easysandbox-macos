#!/usr/bin/env bash
# Prepare the guest disk for QEMU. Sourced before the VM starts.
#
# THE DISK IS EMBEDDED IN THE IMAGE. There is no download, no cache and no
# artifact store: the golden qcow2 ships as an image layer at
# GOLDEN_DISK_IMAGE and this script wraps it in a small OVERLAY so the guest can
# write.
#
# Why an overlay rather than booting the embedded file directly:
#
#   * the image layer is read-only, and a guest must write (system state, user
#     files, the worker's enrollment);
#   * the overlay starts at a few hundred KB and grows only with what is written,
#     so the writable volume stays small;
#   * resetting a sandbox is deleting the overlay — the golden base is never
#     touched, so it cannot be corrupted by anything the guest does.
#
# This replaced a much larger script that could fetch the base from an artifact
# store, cache it, verify a sha256 and either copy or overlay it. All of that
# existed only because the disk was not in the image. With it embedded, the
# runtime work is "create the overlay if missing".
set -Eeuo pipefail

_gd_log() { printf '[golden-disk] %s\n' "$*" >&2; }
trap '_gd_log "FAILED at line ${LINENO} (rc=$?)"' ERR

# The golden base inside the image. Deliberately NOT under /storage: /storage is
# where the writable volume is mounted, and a mount there would hide it.
: "${GOLDEN_DISK_IMAGE:="/opt/golden-disk/data.qcow2"}"
: "${DISK_FILE:="/storage/15/data.qcow2"}"

[ -s "${GOLDEN_DISK_IMAGE}" ] || {
  _gd_log "golden disk missing from the image: ${GOLDEN_DISK_IMAGE}"
  _gd_log "this image should embed it; a disk-less build is no longer supported"
  exit 1
}

mkdir -p "$(dirname "${DISK_FILE}")"

if [ -s "${DISK_FILE}" ]; then
  _gd_log "overlay present, reusing: ${DISK_FILE}"
else
  _gd_log "creating overlay ${DISK_FILE} backed by ${GOLDEN_DISK_IMAGE}"
  tmp="${DISK_FILE}.new.$$"
  # -F qcow2 states the backing format, so qemu never has to probe it.
  qemu-img create -f qcow2 -b "${GOLDEN_DISK_IMAGE}" -F qcow2 "${tmp}" >/dev/null
  mv -f "${tmp}" "${DISK_FILE}"
  _gd_log "overlay ready: $(stat -c%s "${DISK_FILE}") bytes"
fi

export DISK_FMT="qcow2"
return 0
