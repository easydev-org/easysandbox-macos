#!/usr/bin/env bash
# AgentWorker: materialize the guest disk from the artifact-published golden
# base, then hand qemu a per-sandbox OVERLAY — so the image does NOT embed the
# (multi-GB) disk.
#
#   GOLDEN_DISK_URL  the base qcow2 to fetch (e.g.
#                    http://artifact.worker.svc.cluster.local/artifacts/generic/golden-macos/15/data.qcow2)
#   GOLDEN_DISK_SHA  optional expected sha256 (verified when set)
#   GOLDEN_DISK_CACHE  shared cache dir (default /storage/.cache); the base is
#                    downloaded ONCE per node/pod, then shared read-only by
#                    every sandbox overlay.
#   DISK_FILE        the qcow2 qemu boots. Each IMAGE sets this in its ENV
#                    (macOS: /storage/15/data.qcow2; Windows: /storage/data.qcow2);
#                    the default below is only a fallback.
#   DISK_SIZE        qcow2 virtual size (default 128G), only used if we must
#                    create a fresh disk (no base).
#
# Back-compat: when GOLDEN_DISK_URL is unset, do NOTHING — the image-embedded
# disk (if any) is used as-is. Set EMBED_DISK=0 at build time to drop the disk
# from the image entirely (then GOLDEN_DISK_URL is required at run time).
#
# Sourced by start.sh (before qemu). Idempotent: a second run reuses the
# cached base + existing overlay.
set -Eeuo pipefail

_gd_log() { printf '[golden-disk] %s\n' "$*" >&2; }
# On ANY failure, print the exact line + exit code so the container log (the
# only diagnostic we get from a failed sandbox) pinpoints the cause.
trap '_gd_log "FAILED at line ${LINENO} (rc=$?)"' ERR

: "${GOLDEN_DISK_URL:=""}"
: "${GOLDEN_DISK_SHA:=""}"
: "${GOLDEN_DISK_CACHE:="/storage/.cache"}"
: "${DISK_FILE:="/storage/data.qcow2"}"
: "${DISK_SIZE:="128G"}"
# A READ-ONLY golden master, when mounted, is used as the qcow2 BACKING FILE and
# every write goes to an overlay on the writable volume. Set GOLDEN_RO_FILE to
# its path (e.g. /storage/golden/data.qcow2) to enable this mode.
: "${GOLDEN_RO_FILE:=""}"

# With a read-only master mounted there is nothing to download, so an empty
# GOLDEN_DISK_URL is EXPECTED and must not short-circuit here — doing so skipped
# the overlay creation and left the boot with no disk at all
# ("No guest disk at /storage/data.qcow2").
if [ -z "${GOLDEN_DISK_URL}" ] && [ -z "${GOLDEN_RO_FILE}" ]; then
  _gd_log "GOLDEN_DISK_URL unset; using the image-embedded disk (${DISK_FILE})"
  return 0
fi
if [ -n "${GOLDEN_RO_FILE}" ]; then
  _gd_log "read-only master mode: overlay ${DISK_FILE} <- ${GOLDEN_RO_FILE}"
  _gd_ro_mode=1
fi

_gd_log "start: url=${GOLDEN_DISK_URL} disk=${DISK_FILE} cache=${GOLDEN_DISK_CACHE}"
command -v qemu-img >/dev/null 2>&1 || { _gd_log "qemu-img not found"; exit 1; }

# Read-only master mode: no fetch, no cache — go straight to building the
# overlay further down. The whole download/verify block below is meaningless
# when the base is a mounted file.
if [ -z "${GOLDEN_RO_FILE}" ]; then

mkdir -p "${GOLDEN_DISK_CACHE}"
avail_kb=$(df -Pk "${GOLDEN_DISK_CACHE}" | awk 'NR==2{print $4}')
_gd_log "free space at ${GOLDEN_DISK_CACHE}: $((avail_kb/1024)) MiB"
key="$(printf '%s' "${GOLDEN_DISK_URL}" | sha256sum | cut -c1-16)"
base="${GOLDEN_DISK_CACHE}/base-${key}.qcow2"

# --- content-aware invalidation --------------------------------------------
# A cache keyed on the URL ALONE never notices that the artifact at that URL was
# REPLACED (a re-baked golden disk uploaded to the same path). Probe the remote's
# size and drop a stale cached copy so it is re-fetched below.
_gd_remote_meta() {
  local hdrs clen
  command -v curl >/dev/null 2>&1 || return 0
  hdrs="$(curl -fsSL -I --connect-timeout 20 "${GOLDEN_DISK_URL}" 2>/dev/null || true)"
  [ -n "${hdrs}" ] || return 0
  clen="$(printf '%s\n' "${hdrs}" | awk 'tolower($1)=="content-length:"{v=$2} END{print v}' | tr -d '\r')"
  [ -n "${clen}" ] && printf '%s' "${clen}"
}
if [ -s "${base}" ]; then
  want="$(_gd_remote_meta)"
  if [ -n "${want}" ] && [ "$(wc -c <"${base}")" != "${want}" ]; then
    _gd_log "cached base is STALE (cached=$(wc -c <"${base}")B remote=${want}B); refetching"
    rm -f "${base}"
  fi
fi

# --- fetch the base once (shared, read-only) --------------------------------
if [ ! -s "${base}" ]; then
  _gd_log "fetching base ${GOLDEN_DISK_URL} -> ${base}"
  # Stream to a temp file, verify, then rename atomically. `curl` (or wget)
  # with a proxy from the env if present.
  tmp="${base}.part.$$"
  if command -v curl >/dev/null 2>&1; then
    curl -fSL --retry 5 --retry-delay 3 --connect-timeout 20 -o "${tmp}" "${GOLDEN_DISK_URL}" \
      || { _gd_log "download failed: ${GOLDEN_DISK_URL}"; exit 1; }
  else
    wget -O "${tmp}" "${GOLDEN_DISK_URL}" || { _gd_log "download failed: ${GOLDEN_DISK_URL}"; exit 1; }
  fi
  sz=$(wc -c <"${tmp}")
  _gd_log "downloaded ${sz} bytes"
  [ "${sz}" -gt 1048576 ] || { _gd_log "downloaded file too small (${sz} bytes)"; exit 1; }
  if [ -n "${GOLDEN_DISK_SHA}" ]; then
    got="$(sha256sum "${tmp}" | awk '{print $1}')"
    if [ "${got}" != "${GOLDEN_DISK_SHA}" ]; then
      rm -f "${tmp}"
      _gd_log "sha256 mismatch: got ${got} want ${GOLDEN_DISK_SHA}"
      exit 1
    fi
  fi
  mv -f "${tmp}" "${base}"
  chmod 0444 "${base}" 2>/dev/null || true
else
  _gd_log "base already cached at ${base}"
fi

# Sanity: the base must be a qcow2. NOTE: parse the human `file format:` line —
# `qemu-img info --output=json` also contains a child-node `"format":"file"`
# (the protocol layer), and a greedy match on `"format"` picks THAT up
# (a real bug: it wrongly rejected a valid qcow2 as "not a qcow2").
fmt="$(qemu-img info "${base}" 2>/dev/null | awk -F': ' '/^file format:/{print $2; exit}' || true)"
if [ "${fmt}" != "qcow2" ]; then
  _gd_log "base is not a qcow2 (detected '${fmt}'): ${base}"
  exit 1
fi

fi  # end of the fetch/verify path (skipped in read-only master mode)

# --- the live disk -----------------------------------------------------------
# Two modes, chosen by whether a read-only golden master is mounted.
#
# (a) GOLDEN_RO_FILE set — the master is on a READ-ONLY volume, so it can never
#     be modified, and DISK_FILE is an OVERLAY whose backing file is the master.
#     Every guest write lands in the overlay (a few MB at first), which lives on
#     the writable PVC. Resetting a sandbox is then "delete the overlay", and the
#     master stays pristine forever. This is why the master is read-only: a
#     Windows update must not be able to redefine what "golden" means.
#
# (b) not set — the legacy behaviour: seed a STANDALONE copy of the base on the
#     writable PVC and reuse it as-is. Kept for images that still embed a disk or
#     mount a single writable volume.
mkdir -p "$(dirname "${DISK_FILE}")"
if [ -n "${GOLDEN_RO_FILE}" ]; then
  [ -s "${GOLDEN_RO_FILE}" ] || { _gd_log "read-only golden master missing: ${GOLDEN_RO_FILE}"; exit 1; }
  # No cache to clean here: read-only master mode never downloaded a base, so
  # `base` is undefined (and `set -u` would abort on referencing it).
  if [ -s "${DISK_FILE}" ]; then
    _gd_log "overlay present, reusing: ${DISK_FILE} (backing ${GOLDEN_RO_FILE})"
  else
    _gd_log "creating overlay ${DISK_FILE} backed by read-only ${GOLDEN_RO_FILE}"
    tmp="${DISK_FILE}.new.$$"
    # -F qcow2: state the backing format so qemu does not have to probe (and so
    # the overlay keeps working if the master path is later mounted read-only).
    qemu-img create -f qcow2 -b "${GOLDEN_RO_FILE}" -F qcow2 "${tmp}" >/dev/null \
      || { _gd_log "qemu-img create (backing) failed"; exit 1; }
    mv -f "${tmp}" "${DISK_FILE}"
  fi
else
  if [ -s "${DISK_FILE}" ]; then
    _gd_log "persistent disk present, reusing as-is: ${DISK_FILE}"
  else
    _gd_log "seeding persistent disk from golden base: ${DISK_FILE}"
    tmp="${DISK_FILE}.seed.$$"
    qemu-img convert -O qcow2 "${base}" "${tmp}"
    mv -f "${tmp}" "${DISK_FILE}"
  fi
  # The standalone disk no longer depends on the shared base, so drop the cache
  # to keep the (often small) PVC from carrying a second multi-GB copy.
  rm -f "${base}" 2>/dev/null || true
fi

export DISK_FMT="qcow2"
return 0
