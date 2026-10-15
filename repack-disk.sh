#!/usr/bin/env bash
# Shrink the agent-worker macOS golden-disk OCI layer.
#
# The macOS VM images are dominated by one layer: the pre-baked guest qcow2.
# The committed golden stores its clusters internally compressed (zlib), so its
# bytes are already incompressible and the outer layer buys nothing — the zstd
# layer sits at ~14.85 GB for a 15.27 GB file.
#
# This script re-does two things, in order:
#
#   1. defragment the qcow2 to *uncompressed* 1 MiB clusters
#      (`qemu-img convert -O qcow2 -o cluster_size=1M`, no `-c`). This drops
#      dead clusters and leaves the payload compressible again.
#   2. compress that with a 27-bit (128 MiB) zstd window, which finds the
#      large-scale APFS repetition an 8 MiB window misses.
#
# Measured on the base disk (20.10 GB defragged):
#
#   shipped (no defrag, buildkit default zstd)      14.85 GB
#   defrag + buildkit zstd -19 (8 MiB window)       13.92 GB
#   defrag + zstd -19 --long=27                    ~12.58 GB   <- this script
#   defrag + zstd --ultra -22 --long=27            ~12.53 GB   (not worth it)
#
# The win is the defrag plus the long window, not the level. Guest-side
# zero-fill/fstrim before commit is a no-op (APFS already trims) and a raw
# image compresses the same as the qcow2.
#
# buildkit cannot set a long window, so the disk layer is recompressed here and
# swapped into the manifest by hand: decompress the existing layer, tar the
# defragged qcow2, compress it, then patch `layers[i]` and
# `rootfs.diff_ids[i]`. containerd accepts such layers (verified by running a
# pod from one). The guest is byte-identical, so old and new tags are
# interchangeable.
#
# Usage:
#   defrag:  qemu-img convert -f qcow2 -O qcow2 -o cluster_size=1M \
#              golden.qcow2  golden.defrag.qcow2
#   repack:  ./repack-disk.sh <kind> <golden.defrag.qcow2> <srctag> <dsttag>
#     e.g.   ./repack-disk.sh base /work/basic.defrag.qcow2 v1.4.0-base v1.5.0-base
#
# Env: REGISTRY (default git.agent.svc.cluster.local),
#      NAMESPACE (default sandbox), NAME (default sandbox-macos),
#      ZSTD_LEVEL (19), ZSTD_WINDOW (27), ZSTD_THREADS (4), WORK (scratch dir).
set -Eeuo pipefail

KIND="${1:?kind (tag suffix, e.g. base)}"
DISK="${2:?defragged qcow2}"
SRCTAG="${3:?source tag}"
DSTTAG="${4:?destination tag}"

REGISTRY="${REGISTRY:-git.agent.svc.cluster.local}"
NAMESPACE="${NAMESPACE:-sandbox}"
NAME="${NAME:-sandbox-macos}"
REF="$REGISTRY/$NAMESPACE/$NAME"
LEVEL="${ZSTD_LEVEL:-19}"
WINDOW="${ZSTD_WINDOW:-27}"
THREADS="${ZSTD_THREADS:-4}"
W="${WORK:-./repack-$KIND}"

for bin in qemu-img skopeo zstd tar python3; do
  command -v "$bin" >/dev/null || { echo "missing $bin" >&2; exit 1; }
done

rm -rf "$W"; mkdir -p "$W/stage/storage/15"
cd "$W"

echo "===== 1. pull $SRCTAG ====="
skopeo copy --src-tls-verify=false --src-creds "${FORGEJO_USER:-root}:${FORGEJO_PASS:-devpassword}" \
  "docker://$REF:$SRCTAG" "dir:$W/img"

echo
echo "===== 2. locate the disk layer (largest) ====="
python3 - "$W/img/manifest.json" > "$W/meta.txt" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
i = max(range(len(m["layers"])), key=lambda k: m["layers"][k]["size"])
l = m["layers"][i]
print(i)
print(l["size"])
print(l["digest"].split(":")[1])
print(m["config"]["digest"].split(":")[1])
PY
IDX=$(sed -n 1p "$W/meta.txt")
OLDSZ=$(sed -n 2p "$W/meta.txt")
OLDHEX=$(sed -n 3p "$W/meta.txt")
CFG=$(sed -n 4p "$W/meta.txt")
echo "disk layer[$IDX] $(numfmt --to=iec "$OLDSZ") $OLDHEX"

echo
echo "===== 3. tar the defragged disk ====="
cp --reflink=auto "$DISK" "$W/stage/storage/15/data.qcow2" 2>/dev/null \
  || cp "$DISK" "$W/stage/storage/15/data.qcow2"
tar -C "$W/stage" -cf "$W/disk.tar" storage/15/data.qcow2
DIFF="sha256:$(sha256sum "$W/disk.tar" | awk '{print $1}')"
echo "tar=$(numfmt --to=iec "$(stat -c %s "$W/disk.tar")") diff_id=$DIFF"

echo
echo "===== 4. compress: zstd -$LEVEL --long=$WINDOW -T$THREADS ====="
time zstd "-$LEVEL" "--long=$WINDOW" -T"$THREADS" -q -f -o "$W/disk.tar.zst" "$W/disk.tar"
NEWHEX=$(sha256sum "$W/disk.tar.zst" | awk '{print $1}')
NEWSZ=$(stat -c %s "$W/disk.tar.zst")
echo "blob=$(numfmt --to=iec "$NEWSZ") $NEWHEX"
rm -f "$W/disk.tar" "$W/img/$OLDHEX"
cp "$W/disk.tar.zst" "$W/img/$NEWHEX"

echo
echo "===== 5. patch manifest + config ====="
python3 - "$W/img" "$IDX" "$NEWHEX" "$NEWSZ" "$CFG" "$DIFF" <<'PY'
import hashlib, json, os, sys
d, idx, newhex, newsz, cfghex, diff = sys.argv[1:7]
idx = int(idx)
mp = os.path.join(d, "manifest.json")
m = json.load(open(mp))
# A zstd layer only exists in the OCI media-type world; switch the manifest and
# config to OCI (skopeo refuses an OCI zstd layer inside a docker v2s2 manifest).
m["mediaType"] = "application/vnd.oci.image.manifest.v1+json"
m["config"]["mediaType"] = "application/vnd.oci.image.config.v1+json"
m["layers"][idx] = {"mediaType": "application/vnd.oci.image.layer.v1.tar+zstd",
                    "size": int(newsz), "digest": "sha256:" + newhex}
cfgp = os.path.join(d, cfghex)
c = json.load(open(cfgp))
c["rootfs"]["diff_ids"][idx] = diff
open(cfgp, "w").write(json.dumps(c, indent=2))
newcfg = hashlib.sha256(open(cfgp, "rb").read()).hexdigest()
os.rename(cfgp, os.path.join(d, newcfg))
m["config"] = {"mediaType": "application/vnd.oci.image.config.v1+json",
               "digest": "sha256:" + newcfg,
               "size": os.stat(os.path.join(d, newcfg)).st_size}
open(mp, "w").write(json.dumps(m, indent=2))
tot = sum(l["size"] for l in m["layers"])
print("config -> %s" % newcfg[:16])
print("total   = %d (%.2f GiB)" % (tot, tot / 2**30))
PY

echo
echo "===== 6. push $DSTTAG ====="
skopeo copy --format oci --dest-tls-verify=false --dest-creds "${FORGEJO_USER:-root}:${FORGEJO_PASS:-devpassword}" \
  "dir:$W/img" "docker://$REF:$DSTTAG"
skopeo inspect --creds "${FORGEJO_USER:-root}:${FORGEJO_PASS:-devpassword}" --tls-verify=false \
  "docker://$REF:$DSTTAG" | grep '"Digest"' | head -1
echo "REPACKED_$KIND"
