#!/usr/bin/env bash
# Build and push the agent-worker macOS (Sequoia) VM image.
#
#   ./agent-toolchain/vm/macos/build.sh [base|xcode]
#
# The image is a self-owned runtime (the generic qemux/qemu base + the vendored
# boot scripts in vendor/) wrapped around a pre-baked guest disk. Supply a
# *defragged* disk (uncompressed 1 MiB clusters) or the OCI layer will not
# compress — see repack-disk.sh.
#
# The worker binary is boot-fetched by the guest from nginx :8090 /worker; the
# darwin binary COPYed here is the disk fallback.
#
# Expected layout (git-ignored, staged outside the repo):
#   <variant>/disk/data.qcow2        the guest disk
#   <variant>/disk/support/          boot.img, macos.rom/vars, identity
#
# Prerequisites: dist/agent-worker-darwin-amd64 (scripts/build-all.sh).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/../../.." && pwd)"

VARIANT="${1:-base}"
case "$VARIANT" in
  base|xcode) ;;
  *) echo "usage: build.sh [base|xcode]" >&2; exit 2 ;;
esac

# base/xcode -> sandbox-macos (a macOS guest with Xcode; the `base` variant is
# Xcode-ready — there is no separate iOS image).
NAME_DEFAULT="sandbox-macos"
WORKER_OS=""
# The DEFAULT golden disk baked into the image ENV (per variant). This makes a
# disk-less image self-sufficient: it boots even when the caller/deployment did
# NOT inject GOLDEN_DISK_URL (a pod env still overrides it). Without this, a
# VM started without the env has NO disk and dockur falls back to INSTALLING
# macOS (which fails: no OVMF in the runtime image).
GOLDEN_DISK_URL_DEFAULT="http://artifact.worker.svc.cluster.local/artifacts/generic/golden-macos/15/data-xcode3.qcow2"
GOLDEN_DISK_URL="${GOLDEN_DISK_URL:-${GOLDEN_DISK_URL_DEFAULT}}"

# Base images (qemu, udfread) come from the official docker.io/qemux path; the
# cluster buildkitd's registry mirror serves them from the in-cluster artifact.
REGISTRY="${REGISTRY:-artifact.worker.svc.cluster.local}"
REGISTRY_NS="${REGISTRY_NS-qemux}"
# Where the built image is PUSHED (always the in-cluster artifact registry).
PUSH_REGISTRY="${PUSH_REGISTRY:-artifact.worker.svc.cluster.local}"
NAMESPACE="${NAMESPACE:-sandbox}"
NAME="${NAME:-${NAME_DEFAULT}}"
TAG="${TAG:-${VARIANT}}"
DEST="${PUSH_REGISTRY}/${NAMESPACE}/${NAME}:${TAG}"
BUILDKIT="${BUILDKIT_ADDR:-tcp://buildkitd.agent.svc.cluster.local:1234}"
PROXY="${PROXY:-http://mihomo.develop.svc.cluster.local:7890}"
# Keep in-cluster traffic OFF the proxy (buildctl gRPC to buildkitd, the
# artifact registry). Both spellings: some tools read no_proxy, others NO_PROXY.
NO_PROXY="${NO_PROXY:-localhost,127.0.0.1,.svc,.svc.cluster.local,.cluster.local,artifact.worker.svc.cluster.local,buildkitd.worker.svc.cluster.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16}"
no_proxy="${no_proxy:-$NO_PROXY}"
export NO_PROXY no_proxy
DISK="${DISK:-${DIR}/${VARIANT}/data.qcow2}"
SUPPORT="${SUPPORT:-${DIR}/${VARIANT}/support}"
# Both guest binaries come from GitHub releases (see the Containerfile), so the
# build only needs the versions, not staged files.
WORKER_VERSION="${WORKER_VERSION:-v0.0.1}"
EASYSTREAM_VERSION="${EASYSTREAM_VERSION:-v0.0.1}"
BUILDCTL="${BUILDCTL:-$(command -v buildctl || true)}"
# EMBED_DISK=0 builds a disk-less image (the guest disk is fetched at run time
# from the artifact golden base + per-sandbox overlay — see golden-disk.sh).
EMBED_DISK="${EMBED_DISK:-1}"

for f in "${DIR}/Containerfile" "${DIR}/00-token.conf" "${DIR}/start.sh" "${DIR}/golden-disk.sh"; do
  [ -e "$f" ] || { echo "missing $f" >&2; exit 1; }
done
[ "${EMBED_DISK}" = "1" ] && [ ! -e "${DISK}" ] && { echo "missing disk ${DISK} (or set EMBED_DISK=0)" >&2; exit 1; }
[ -d "${SUPPORT}" ] || { echo "missing support dir ${SUPPORT}" >&2; exit 1; }
[ -n "${BUILDCTL}" ] || { echo "buildctl not found (set BUILDCTL)" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/disk/support"
cp "${DIR}/Containerfile" "${WORK}/Dockerfile"
cp "${DIR}/00-token.conf" "${DIR}/start.sh" "${WORK}/"
# NOTE: neither the worker nor easystream is staged here — the Containerfile
# fetches both from their GitHub releases (WORKER_VERSION / EASYSTREAM_VERSION).
cp -r "${DIR}/vendor" "${WORK}/vendor"
cp -r "${DIR}/guest"  "${WORK}/guest"
cp "${DIR}/golden-disk.sh" "${WORK}/"
if [ "${EMBED_DISK}" = "1" ]; then
  ln "${DISK}" "${WORK}/disk/data.qcow2" 2>/dev/null || cp "${DISK}" "${WORK}/disk/data.qcow2"
else
  : > "${WORK}/disk/data.qcow2"   # placeholder; Containerfile removes it when EMBED_DISK=0
fi
# Boot support only; base.dmg (install media) is not shipped (see Containerfile).
for f in boot.img boot.sig macos.id macos.mac macos.mlb macos.rom macos.sn macos.vars; do
  [ -e "${SUPPORT}/$f" ] && cp -f "${SUPPORT}/$f" "${WORK}/disk/support/"
done

echo "Building ${NAME}:${TAG} -> ${DEST} (buildkitd=${BUILDKIT})"
echo "  disk: $(du -h "${WORK}/disk/data.qcow2" | cut -f1) (EMBED_DISK=${EMBED_DISK})"
"${BUILDCTL}" --addr "${BUILDKIT}" build \
  --frontend dockerfile.v0 \
  --local "context=${WORK}" \
  --local "dockerfile=${WORK}" \
  --opt "filename=Dockerfile" \
  --opt "build-arg:REGISTRY=${REGISTRY}${REGISTRY_NS:+/${REGISTRY_NS}}" \
  --opt "build-arg:ARTIFACT=${ARTIFACT:-http://artifact.worker.svc.cluster.local}" \
  --opt "build-arg:HTTP_PROXY=${PROXY}" \
  --opt "build-arg:HTTPS_PROXY=${PROXY}" \
  --opt "build-arg:EMBED_DISK=${EMBED_DISK}" \
  --opt "build-arg:WORKER_VERSION=${WORKER_VERSION}" \
  --opt "build-arg:EASYSTREAM_VERSION=${EASYSTREAM_VERSION}" \
  --opt "build-arg:RELEASE_PROXY=${PROXY}" \
  --opt "build-arg:WORKER_OS=${WORKER_OS}" \
  --opt "build-arg:GOLDEN_DISK_URL=${GOLDEN_DISK_URL}" \
  --output "type=oci,dest=${WORK}/image.oci,compression=zstd" \
  --progress plain

echo "Pushing to ${DEST}"
mkdir -p "${WORK}/oci" && tar -xf "${WORK}/image.oci" -C "${WORK}/oci"
skopeo copy --src-tls-verify=false --dest-tls-verify=false \
  --dest-creds "${FORGEJO_USER:-root}:${FORGEJO_PASS:-devpassword}" \
  "oci:${WORK}/oci" "docker://${DEST}"

echo "Verifying push:"
skopeo inspect --creds "${FORGEJO_USER:-root}:${FORGEJO_PASS:-devpassword}" \
  --tls-verify=false "docker://${DEST}" >/dev/null 2>&1 \
  && echo "OK ${DEST}" \
  || echo "inspect failed for ${DEST} (image may still be present)"
