# agent-worker macOS image

The agent-worker macOS (Sequoia) sandbox: a self-owned runtime (the generic
`qemux/qemu` Debian base + the vendored boot scripts in `vendor/`) wrapped
around a pre-baked guest disk that already contains the worker, its launcher and
the LaunchAgent/LaunchDaemon. No upstream sandbox image is referenced.

## Variants

| tag | contents |
|---|---|
| `base`  | Sequoia + worker + computer-use (xa11y) — plain macOS sandbox |
| `xcode` | + full **Xcode.app** (SDKs), **first-launch done** |

Both variants build to `sandbox-macos` (`xcode` → `sandbox-macos:xcode`, via
`build.sh xcode`).

The workspace is `/Users/docker/workspace` (uniform with the Linux sandboxes'
`/workspace` basename; the Windows sandbox uses `C:\Users\Docker\workspace`).

Both tags carry computer-use: the guest disk ships the `xa11y` binary at
`/usr/local/bin/xa11y` and the launcher grants it the Accessibility (TCC)
permission.

### Rebaking `xcode`

The xcode disk is a `base` disk plus a full Xcode install. The `.xip` is
Apple-ID-gated on `download.developer.apple.com` (returns an "Unauthorized"
HTML page), so the bake pulls the **same build from archive.org** — no Apple ID:

```sh
# in the guest (needs the proxy for archive.org; SIP off so xcode-select works):
curl -fSL -x http://mihomo.develop.svc.cluster.local:7890 \
  -o Xcode.xip https://archive.org/download/xcode-26.3/Xcode_26.3_Universal.xip
# verify md5 against archive.org's metadata, then:
xip --expand Xcode.xip                       # -> ./Xcode.app
sudo mv Xcode.app /Applications/
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept

# FIRST-LAUNCH — mandatory, or the first `xcodebuild`/`simctl` at RUN time pops a
# password prompt and hangs. Run non-interactively as root (docker has
# passwordless sudo, and this is also what the sandbox's passwordless sudo runs):
sudo -n xcodebuild -runFirstLaunch
```

Produces Xcode 26.3 (17C529) with the full SDK set, first-launch done. That is
the `xcode` disk (`sandbox-macos:xcode`).

The disk ships the `xa11y` binary at `/usr/local/bin/xa11y`, so `xcode` also has
computer-use (the macos xa11y driver).

## Layout

- `Containerfile` — self-owned runtime: `FROM <registry>/qemu:750`, the OpenCore
  boot-image rebuild tools, the vendored boot scripts, the pre-baked disk +
  boot support, the boot-fetched worker + xa11y binary, and the token bridge.
- `build.sh` — build + push (buildkitd → skopeo → the registry). Variants:
  `base` and `xcode`.
- `repack-disk.sh` — shrink the disk layer (defrag + long-window zstd).
- `vendor/` — boot scripts (`run/`), the OpenCore `config.plist`, and the
  OpenCore/VMHide archives.
- `guest/` — files baked *into the guest disk*:
  - `worker-launch.sh` — fetches the per-pod env (WORKER_TOKEN/SANDBOX_PROXY)
    from `host.lan:8090/env`, boot-fetches the worker from `host.lan:8090/worker`,
    grants TCC (the `xa11y`/`ffmpeg` binaries are baked into the disk), and starts
    the worker in docker's Aqua session.
  - `bake-guest.sh` — one-time bake: passwordless sudo, launchd units,
    auto-login.

## computer-use (xa11y)

The guest runs a **self-contained xa11y Mach-O binary** (baked into the disk at
`/usr/local/bin/xa11y`) and drives native apps through AXUIElement. It links only system frameworks
(`/System/Library/Frameworks/*`, `/usr/lib/libSystem.B.dylib`), so the sandbox
needs **no Command Line Tools and no Python** — earlier iterations shipped the
prebuilt Python wheel, which forced a full CLT install (+~2.4 GiB).

Two things make it work, both baked into the golden disk:

1. **SIP off.** `config.plist` sets `csr-active-config=0x7f` AND lists
   `csr-active-config` under NVRAM/`Delete`, so the stale `0x00` in the
   pre-baked `macos.vars` no longer wins. Changing `config.plist` changes
   `openCoreSignature()`, so `boot.sh` rebuilds the OpenCore image on boot —
   which is why the Containerfile installs `xmlstarlet mtools file zip`.
2. **TCC Accessibility + ScreenCapture.** macOS attributes the permission to
   the RESPONSIBLE process, so the launcher (running as root, with SIP off and
   a writable TCC db) grants it to the worker AND to xa11y itself on every
   boot. No CLT/Python is involved.

### Building the xa11y binary

macOS cannot be cross-compiled (Apple frameworks + Objective-C). There is no
prebuilt CLI binary upstream, so build it once inside a throwaway macOS guest
and stage the result into `dist/`:

```sh
# boot a scratch copy of the sandbox-macos:base disk as a KVM pod, then in-guest:
softwareupdate -i "Command Line Tools for Xcode-16.4"        # compile-time only
curl -sL https://static.rust-lang.org/dist/2026-07-16/rust-1.97.1-x86_64-apple-darwin.tar.xz \
  | tar -xJ -C /tmp/rust --strip-components=1 && /tmp/rust/install.sh --prefix=/Users/docker/rust --without=rust-docs
curl -sL https://codeload.github.com/xa11y/xa11y/tar.gz/refs/tags/v0.15.0 | tar -xz -C /tmp/xa11y --strip-components=1
cd /tmp/xa11y && RUSTC=/Users/docker/rust/bin/rustc PATH=/Users/docker/rust/bin:$PATH \
  /Users/docker/rust/bin/cargo build --release -p xa11y --bin xa11y   # ~13 min
# extract target/release/xa11y to dist/xa11y-darwin-amd64
```

The CLT/Rust live only in that throwaway guest — the sandbox disk is untouched.

## Building the image

```sh
# stage (git-ignored): agent-toolchain/vm/macos/<variant>/data.qcow2
#                      agent-toolchain/vm/macos/<variant>/support/
scripts/build-all.sh                        # dist/agent-worker-darwin-amd64
scripts/build-xa11y.sh macos                # checks dist/xa11y-darwin-amd64
./agent-toolchain/vm/macos/build.sh base
./agent-toolchain/vm/macos/build.sh xcode

# optional: shrink the disk layer
qemu-img convert -f qcow2 -O qcow2 -o cluster_size=1M,lazy_refcounts=on \
  base/data.qcow2 base/defrag.qcow2
./agent-toolchain/vm/macos/repack-disk.sh base base/defrag.qcow2 <src> <dst>
```

The golden disk can be extracted straight from the published image (no
node-local copy needed): `skopeo copy docker://…/sandbox-macos:base dir:…`,
then `zstd -d | tar -x` the largest layer (`storage/15/data.qcow2`) and the
small `disk/support/*` layers (`storage/15/macos.*`). To rebake, boot that disk
as a hostPath `/storage` (a KVM pod on the image's node), write the new
launcher into the guest, verify `xa11y apps` after a reboot, shut down, defrag,
then build a fresh image and push it as `base`.
