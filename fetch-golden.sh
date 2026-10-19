#!/usr/bin/env bash
# fetch-golden.sh — rebuild a golden guest disk from its ghcr.io shards.
#
#   ./fetch-golden.sh windows /storage/data.qcow2
#   ./fetch-golden.sh macos   /storage/15/data.qcow2
#
# The disks are multi-GB (15 / 18 GiB), which no single GitHub store can hold:
#   * Git LFS caps a file at 2 GiB (Free/Pro) / 5 GiB (Enterprise)
#   * Release assets must be < 2 GiB
#   * an OCI layer caps at 10 GiB AND the upload times out after 10 minutes
# So each disk is split into <4 GiB shards and each shard is published as a
# single-layer OCI image on ghcr.io (which has no total-size limit).
#
# This pulls the shards anonymously, extracts the raw part from each layer,
# joins them, and verifies the sha256 of the whole disk before writing it.
#
# Needs skopeo (or docker/podman). Anonymous pull works for these packages.
set -Eeuo pipefail

WHICH="${1:?usage: $0 <windows|macos> <out.qcow2>}"
OUT="${2:?usage: $0 <windows|macos> <out.qcow2>}"

case "$WHICH" in
  windows)
    REPO=ghcr.io/silvermelon233/golden-windows; PREFIX=win11-devtools3
    NSHARDS=5
    SHA=22b93b597268efd6761f22b8e4057854396455ca24892e07f105b63a4ae9ed9e ;;
  macos)
    REPO=ghcr.io/silvermelon233/golden-macos;   PREFIX=macos15-xcode3
    NSHARDS=5
    SHA=0e31229c53f579337c14f9f8ea064e1ec980dbe6a30933a11d1f41634556cb45 ;;
  *) echo "unknown disk: $WHICH (windows|macos)" >&2; exit 2 ;;
esac

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
echo "fetching $NSHARDS shard(s) from $REPO ($PREFIX.*)"
: > "$WORK/disk.qcow2"
for i in $(seq -f "%02g" 0 $((NSHARDS-1))); do
  t="$PREFIX.$i"; echo "  - $t"
  skopeo copy "docker://$REPO:$t" "dir:$WORK/d$t"
  # The dir holds the layer blob, the config blob and manifest.json; the LAYER
  # is by far the largest file (the config is a few hundred bytes).
  blob=$(find "$WORK/d$t" -maxdepth 1 -type f -printf '%s %p\n' | sort -rn | head -1 | cut -d' ' -f2-)
  tar xzf "$blob" -C "$WORK/d$t"          # -> shards/<name>.part.<i>
  part=$(find "$WORK/d$t" -type f -name "*.part.$i" | head -1)
  cat "$part" >> "$WORK/disk.qcow2"
done
echo "verifying sha256 ..."
got=$(sha256sum "$WORK/disk.qcow2" | awk '{print $1}')
[ "$got" = "$SHA" ] || { echo "SHA256 MISMATCH: got $got want $SHA" >&2; exit 1; }
echo "sha256 ok"
mkdir -p "$(dirname "$OUT")"; mv -f "$WORK/disk.qcow2" "$OUT"
echo "wrote $OUT ($(stat -c%s "$OUT") bytes)"
