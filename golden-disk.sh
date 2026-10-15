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

if [ -z "${GOLDEN_DISK_URL}" ]; then
  _gd_log "GOLDEN_DISK_URL unset; using the image-embedded disk (${DISK_FILE})"
  return 0
fi

_gd_log "start: url=${GOLDEN_DISK_URL} disk=${DISK_FILE} cache=${GOLDEN_DISK_CACHE}"
command -v qemu-img >/dev/null 2>&1 || { _gd_log "qemu-img not found"; exit 1; }

mkdir -p "${GOLDEN_DISK_CACHE}"
avail_kb=$(df -Pk "${GOLDEN_DISK_CACHE}" | awk 'NR==2{print $4}')
_gd_log "free space at ${GOLDEN_DISK_CACHE}: $((avail_kb/1024)) MiB"
key="$(printf '%s' "${GOLDEN_DISK_URL}" | sha256sum | cut -c1-16)"
base="${GOLDEN_DISK_CACHE}/base-${key}.qcow2"

# --- content-aware invalidation --------------------------------------------
# A cache keyed on the URL ALONE never notices that the artifact at that URL was
# REPLACED (a re-baked golden disk uploaded to the same path). The node would
# then serve a stale base forever. Probe the remote's size + validator and, when
# the cached copy no longer matches, drop it so it is re-fetched below.
_gd_remote_meta() {
  # Echo "<size>|<etag-or-last-modified>" for the remote, or "" when unknown.
  local hdrs clen val
  command -v curl >/dev/null 2>&1 || return 0
  hdrs="$(curl -fsSL -I --connect-timeout 20 "${GOLDEN_DISK_URL}" 2>/dev/null || true)"
  [ -n "${hdrs}" ] || return 0
  clen="$(printf '%s\n' "${hdrs}" | awk 'tolower($1)=="content-length:"{v=$2} END{print v}' | tr -d '\r')"
  val="$(printf '%s\n' "${hdrs}" | awk 'tolower($1)=="etag:"{v=$2} tolower($1)=="last-modified:"{v=$2" "$3" "$4" "$5" "$6} END{print v}' | tr -d '\r')"
  [ -n "${clen}${val}" ] && printf '%s|%s' "${clen}" "${val}"
}
if [ -s "${base}" ]; then
  want="$(_gd_remote_meta)"
  if [ -n "${want}" ]; then
    have="$(wc -c <"${base}")"
    want_size="${want%%|*}"
    if [ -n "${want_size}" ] && [ "${have}" != "${want_size}" ]; then
      _gd_log "cached base is STALE (cached=${have}B remote=${want_size}B); refetching"
      rm -f "${base}"
    fi
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

# --- persistent disk (NO overlay) -------------------------------------------
# The disk lives on a PVC (/storage), so it MUST persist across pod restarts:
# the guest's enrollment/token and user state are on it. We therefore seed it
# ONCE from the golden base as a STANDALONE qcow2 (qemu-img convert, no backing
# file) and afterwards reuse it as-is. We do NOT compare it against the golden
# base: a re-baked base (new size/etag) must never wipe a live sandbox's disk.
mkdir -p "$(dirname "${DISK_FILE}")"
if [ -s "${DISK_FILE}" ]; then
  _gd_log "persistent disk present, reusing as-is: ${DISK_FILE}"
else
  _gd_log "seeding persistent disk from golden base: ${DISK_FILE}"
  tmp="${DISK_FILE}.seed.$$"
  # convert copies the base's contents into a self-contained qcow2 (no backing
  # dependency), so the shared read-only base can even be deleted afterwards.
  qemu-img convert -O qcow2 "${base}" "${tmp}"
  mv -f "${tmp}" "${DISK_FILE}"
fi
# The standalone disk no longer depends on the shared base, so drop the cache
# to keep the (often small) PVC from carrying a second multi-GB copy.
rm -f "${base}" 2>/dev/null || true

export DISK_FMT="qcow2"
return 0
