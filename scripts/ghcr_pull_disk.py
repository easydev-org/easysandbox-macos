"""Rebuild a golden qcow2 from its ghcr OCI image.

    ghcr_pull_disk.py <windows|macos> <out.qcow2>

The disk is published as ONE tag whose LAYERS are consecutive pieces of the
qcow2 (`golden-windows:base` has 8, `golden-macos:base` has 9). Concatenating the
layer payloads in manifest order reproduces the original file exactly, and the
result is verified against the sha256 recorded in the manifest annotation before
it is moved into place.

Why not skopeo: it is not installed in the sandbox images, and the whole point of
this script is that a plain machine with python3 can produce the embedded disk.

Auth: the packages are PRIVATE, and ghcr's /token endpoint echoes back
base64(PAT) rather than a registry JWT — that base64 string is what the /v2
endpoints accept as a Bearer token. (Sending the PAT as Basic, or decoding the
base64 first, both give 401.)

Environment: GHCR_TOKEN (a PAT with read:packages).
"""

import base64
import json
import os
import ssl
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

REG = "ghcr.io"
OWNER = "silvermelon233"
USER = "SilverMelon233"

PLAN = {
    "windows": ("golden-windows", "base"),
    "macos": ("golden-macos", "base"),
}

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE


def token(repo, pat):
    basic = base64.b64encode(f"{USER}:{pat}".encode()).decode()
    url = f"https://{REG}/token?scope=repository:{OWNER}/{repo}:pull&service={REG}"
    r = urllib.request.urlopen(
        urllib.request.Request(url, headers={"Authorization": "Basic " + basic}),
        timeout=30, context=ctx)
    return json.load(r)["token"]


def get(url, tok, accept=None):
    h = {"Authorization": "Bearer " + tok}
    if accept:
        h["Accept"] = accept
    return urllib.request.urlopen(urllib.request.Request(url, headers=h),
                                  timeout=120, context=ctx)


def main():
    which, out = sys.argv[1], sys.argv[2]
    repo, tag = PLAN[which]
    pat = os.environ.get("GHCR_TOKEN")
    if not pat:
        sys.exit("set GHCR_TOKEN (PAT with read:packages)")

    tok = token(repo, pat)
    man = json.load(get(f"https://{REG}/v2/{OWNER}/{repo}/manifests/{tag}", tok,
                        "application/vnd.oci.image.manifest.v1+json"))
    layers = man["layers"]
    want = (man.get("annotations") or {}).get("disk.sha256", "")
    print(f"{repo}:{tag}  layers={len(layers)}  expected sha256={want[:16] or '(none)'}")

    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    tmp = out + ".part"
    with open(tmp, "wb") as fh:
        for i, l in enumerate(layers):
            dg = l["digest"]
            sz = l["size"]
            print(f"  layer {i + 1}/{len(layers)}  {sz / 1024 ** 2:8.1f} MB  {dg[:22]}", flush=True)
            with tempfile.NamedTemporaryFile(suffix=".blob", delete=False) as blob:
                bpath = blob.name
            try:
                with get(f"https://{REG}/v2/{OWNER}/{repo}/blobs/{dg}", tok) as r, open(bpath, "wb") as bf:
                    while True:
                        chunk = r.read(1 << 20)
                        if not chunk:
                            break
                        bf.write(chunk)
                # Each layer is a tar holding one part file.
                with tarfile.open(bpath, "r:*") as tf:
                    parts = [m for m in tf.getmembers() if m.isfile()]
                    if not parts:
                        sys.exit(f"layer {i} contains no file")
                    data = tf.extractfile(parts[0]).read()
                fh.write(data)
                print(f"        -> {len(data) / 1024 ** 2:.1f} MB extracted", flush=True)
            finally:
                os.unlink(bpath)

    if want:
        got = subprocess.run(["sha256sum", tmp], capture_output=True, text=True).stdout.split()[0]
        if got != want:
            os.unlink(tmp)
            sys.exit(f"sha256 MISMATCH\ngot  {got}\nwant {want}")
        print(f"sha256 ok: {got}")

    os.replace(tmp, out)
    print(f"wrote {out}: {os.path.getsize(out)} bytes")


if __name__ == "__main__":
    main()
