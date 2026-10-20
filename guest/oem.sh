#!/bin/bash
# macOS guest OEM launch logic (served by nginx :8090 /oem.sh).
#
# Runs in two places (same script):
#   * as `docker` via the LaunchAgent in the Aqua session (normal path), and
#   * as root via the one-shot LaunchDaemon (bootstrap/fallback).
#
# Responsibilities:
#   1. fetch EVERY boot payload in one request from http://host.lan:8090/files,
#      which start.sh packs as a single tar (oem.sh, easyworker, easystream,
#      the audio aggregate helper and the BlackHole driver). One fetch means one
#      failure to report and no nginx edit when a payload is added. An upgrade is
#      still an image change, not a golden-disk change.
#   2. fetch the pod-provided per-pod env (WORKER_TOKEN + SANDBOX_PROXY) from
#      http://host.lan:8090/env
#   3. install BlackHole and run the aggregate helper so system audio is wired
#      before anything tries to capture it
#   4. start easystream, then easyworker, inside docker's GUI session
set -Eeuo pipefail

WROOT=/Users/docker
BIN="$WROOT/easyworker-darwin"
DL="$WROOT/easyworker-darwin.dl"
WS="$WROOT/workspace"
DP="$WROOT/displayplacer"
SCREEN_RESOLUTION="${SCREEN_RESOLUTION:-1920x1080}"
TCC="/Library/Application Support/com.apple.TCC/TCC.db"

# AQUA_UID: the uid of the logged-in GUI user (docker). Screen capture only
# works for processes inside that user's Aqua session, so the daemon must be
# launched with `launchctl asuser $AQUA_UID`.
AQUA_UID="$(id -u docker 2>/dev/null || echo 501)"

# --- make stdout safe -------------------------------------------------------
# This script runs under launchd with KeepAlive=true, where stdout is a pipe
# whose reader may already be gone; the first `echo` then raises SIGPIPE and
# kills the run instantly (observed: oem.sh restarting every ~10s at its first
# echo, with the guest left running nothing but sshd).
#
# So: ignore SIGPIPE, and redirect to a PER-INSTANCE log. Two instances run by
# design (root's LaunchDaemon and docker's LaunchAgent) and a shared append can
# fail for whichever user does not own the file — which killed the script BEFORE
# the /env fetch, so the log must never be shared and must never be fatal.
trap '' PIPE
OEM_LOG="${WROOT:-$HOME}/workspace/oem-$(id -un).log"
mkdir -p "$(dirname "$OEM_LOG")" 2>/dev/null || true
if { true >>"$OEM_LOG"; } 2>/dev/null; then
  exec >>"$OEM_LOG" 2>&1
else
  # Cannot write there: keep going with output discarded rather than die.
  exec >/dev/null 2>&1
fi
echo "=== oem.sh $(date) pid=$$ user=$(id -un) ==="

# --- fetch EVERY boot payload in one request -------------------------------
# The container packs the worker, easystream, this script and the audio helper
# into one tar at /files (see start.sh). One fetch, one failure to report, and
# the container's file list is the single source of truth.
#
# Unpacked to $WROOT/boot so nothing lands on top of a running binary: the worker
# and easystream are replaced below by copying from here, which is safe even if
# the old one is executing.
BOOTDIR="$WROOT/boot"
rm -rf "$BOOTDIR" 2>/dev/null || true
mkdir -p "$BOOTDIR" 2>/dev/null || true
BOOT_OK=0
for _ in $(seq 1 40); do
  if curl -s -m 90 -o "$BOOTDIR.tar" http://host.lan:8090/files 2>/dev/null \
     && [ "$(stat -f%z "$BOOTDIR.tar" 2>/dev/null || echo 0)" -gt 1000 ]; then
    if tar xf "$BOOTDIR.tar" -C "$BOOTDIR" 2>/dev/null; then
      BOOT_OK=1
      break
    fi
  fi
  rm -f "$BOOTDIR.tar" 2>/dev/null || true
  sleep 2
done
if [ "$BOOT_OK" = 1 ]; then
  chmod 755 "$BOOTDIR"/* 2>/dev/null || true
  echo "boot: fetched $(stat -f%z "$BOOTDIR.tar" 2>/dev/null || echo 0) bytes, $(ls "$BOOTDIR" 2>/dev/null | tr '\n' ' ')"
else
  echo "boot: WARNING could not fetch /files; falling back to per-file fetch"
fi

# --- pod env (WORKER_TOKEN + SANDBOX_PROXY) -------------------------------
# The guest does not inherit the pod's env; the container publishes the few
# per-pod values it needs at host.lan:8090/env as KEY=VALUE lines.
PODENV=""
for _ in $(seq 1 60); do
  if PODENV=$(curl -s -m 2 http://host.lan:8090/env 2>/dev/null); then break; fi
  sleep 1
done
WORKER_TOKEN=$(printf '%s\n' "$PODENV" | sed -n 's/^WORKER_TOKEN=//p' | tr -d '\r')
SANDBOX_PROXY=$(printf '%s\n' "$PODENV" | sed -n 's/^SANDBOX_PROXY=//p' | tr -d '\r')
[ -n "$WORKER_TOKEN" ] && export WORKER_TOKEN
# The daemon must be LOCKED: control needs a token (default to the worker's own
# token), view stays open. Without it easystream would run unauthenticated and
# any process that reached :48079/:48078 could drive the guest.
EAZYSTREAM_CONTROL_TOKEN=$(printf '%s\n' "$PODENV" | sed -n 's/^EAZYSTREAM_CONTROL_TOKEN=//p' | tr -d '\r')
EAZYSTREAM_VIEW_TOKEN=$(printf '%s\n' "$PODENV" | sed -n 's/^EAZYSTREAM_VIEW_TOKEN=//p' | tr -d '\r')
[ -n "$EAZYSTREAM_CONTROL_TOKEN" ] || EAZYSTREAM_CONTROL_TOKEN="$WORKER_TOKEN"
export EAZYSTREAM_CONTROL_TOKEN EAZYSTREAM_VIEW_TOKEN
# The deployment HTTP proxy: jobs (git/npm/go) reach the blocked internet only
# through it. Jobs inherit the worker's env, so export it here.
if [ -n "$SANDBOX_PROXY" ]; then
  export HTTP_PROXY="$SANDBOX_PROXY" HTTPS_PROXY="$SANDBOX_PROXY" \
         http_proxy="$SANDBOX_PROXY" https_proxy="$SANDBOX_PROXY"
  export NO_PROXY="localhost,127.0.0.1,.svc,.svc.cluster.local,host.lan,artifact.worker.svc.cluster.local"
  export no_proxy="$NO_PROXY"
  # Also set the SYSTEM proxy so GUI/CFNetwork consumers (Xcode downloads,
  # Safari, curl without env) use it, not just env-var-aware tools. Best-effort.
  if [ "$(id -un)" = "root" ] || sudo -n true 2>/dev/null; then
    PROXY_HOST=$(printf '%s' "$SANDBOX_PROXY" | sed -E 's#^https?://##; s#/.*$##')
    PROXY_PORT=$(printf '%s' "$PROXY_HOST" | sed -E 's/.*://'); PROXY_HOST=${PROXY_HOST%%:*}
    for svc in "Wi-Fi" "Ethernet"; do
      sudo -n networksetup -setwebproxy "$svc" "$PROXY_HOST" "$PROXY_PORT" >/dev/null 2>&1 || true
      sudo -n networksetup -setsecurewebproxy "$svc" "$PROXY_HOST" "$PROXY_PORT" >/dev/null 2>&1 || true
      sudo -n networksetup -setproxybypassdomains "$svc" "*.local" "169.254/16" "*.svc" "*.svc.cluster.local" "host.lan" "localhost" "127.0.0.1" >/dev/null 2>&1 || true
    done
  fi
fi

# WORKER_OS (the sandbox OS) is baked into the golden disk; the macOS image has
# no ~/worker-os file (empty -> macos driver).
if [ -f "$WROOT/worker-os" ]; then
  WORKER_OS=$(tr -d '\r\n' < "$WROOT/worker-os")
  [ -n "$WORKER_OS" ] && export WORKER_OS
fi

mkdir -p "$WS"
cd "$WROOT"

# --- BlackHole: the audio loopback -----------------------------------------
# easystream captures the guest's SYSTEM audio with a BlackHole loopback inside
# a clocked aggregate device. Without the driver there is simply no audio
# capture path: /capabilities reports audio=None and the stream carries video
# only. (This was silently missing: the driver had been installed by hand once
# in a live guest, so a freshly imaged disk had video but no sound.)
#
# The driver ships IN THE IMAGE and is boot-fetched from nginx, exactly like
# oem.sh and the worker: an upgrade is an image change, the guest needs no
# internet, and the build is reproducible from a git clone.
#
# It is a user-space HAL plugin (NOT a kext), so no SIP / kext-consent change is
# needed; coreaudiod rescans the HAL directory on restart.
HB_BH=/Library/Audio/Plug-Ins/HAL/BlackHole.driver
if [ ! -d "$HB_BH" ]; then
  if [ -s "$BOOTDIR/BlackHole.driver-0.7.1.tgz" ] \
     && [ "$(stat -f%z "$BOOTDIR/BlackHole.driver-0.7.1.tgz" 2>/dev/null || echo 0)" -gt 10000 ]; then
    mkdir -p /Library/Audio/Plug-Ins/HAL
    if tar xzf "$BOOTDIR/BlackHole.driver-0.7.1.tgz" -C /Library/Audio/Plug-Ins/HAL/ 2>/dev/null; then
      chown -R root:wheel "$HB_BH" 2>/dev/null || true
      killall coreaudiod 2>/dev/null || true
      # coreaudiod must be BACK before anything talks to CoreAudio. A fixed
      # `sleep 3` was not enough: the aggregate helper then called into a
      # restarting audio stack and the boot stalled right after /aggregate.
      for _ in $(seq 1 30); do
        pgrep -x coreaudiod >/dev/null 2>&1 && break
        sleep 1
      done
      sleep 2
      echo "audio: BlackHole installed"
    else
      echo "audio: WARNING BlackHole unpack failed" >&2
    fi
  else
      echo "audio: WARNING BlackHole unavailable from the image" >&2
    fi
fi

# Wire the loopback: build the "easystream Audio" aggregate (BlackHole clocked by
# the real output) and make it the guest's default output. easystream then only
# has to open the default output and read the PCM back — it does not build or
# manage aggregates itself any more, so a daemon restart no longer changes the
# system's default output device underneath every app.
#
# Idempotent: the helper exits 0 and changes nothing when the aggregate is
# already present and default. It is boot-fetched so an upgrade is an image
# change, exactly like oem.sh itself.
if [ -d "$HB_BH" ]; then
  AGG="$WROOT/aggregate"
  if [ -s "$BOOTDIR/aggregate" ] \
     && [ "$(stat -f%z "$BOOTDIR/aggregate" 2>/dev/null || echo 0)" -gt 5000 ]; then
    cp -f "$BOOTDIR/aggregate" "$AGG.dl" 2>/dev/null \
      && chmod 755 "$AGG.dl" && mv -f "$AGG.dl" "$AGG" 2>/dev/null || true
  fi
  if [ -x "$AGG" ]; then
    # Bound it: a CoreAudio call must never be able to hang the whole launch.
    if command -v timeout >/dev/null 2>&1; then
      timeout 60 "$AGG" 2>&1 | while IFS= read -r l; do echo "audio: $l"; done
    else
      "$AGG" 2>&1 | while IFS= read -r l; do echo "audio: $l"; done
    fi
    echo "audio: aggregate helper done (rc=$?)"
  else
    echo "audio: WARNING aggregate helper unavailable from the image" >&2
  fi
fi

# --- easystream (est://) daemon: boot-fetch + start ------------------------
# The Go worker talks to easystream over est:// on 127.0.0.1:48079. Fetch it
# every boot (image change, never a golden rebake) and start it BEFORE the
# worker so the first /stream/ws connection finds it listening.
NA_BIN="$WROOT/easystream"
if [ -s "$BOOTDIR/easystream" ]; then
  cp -f "$BOOTDIR/easystream" "$NA_BIN.dl" 2>/dev/null || true
  if [ "$(stat -f%z "$NA_BIN.dl" 2>/dev/null || echo 0)" -gt 10000 ]; then
    chmod 755 "$NA_BIN.dl"
    mv -f "$NA_BIN.dl" "$NA_BIN" 2>/dev/null || true
  fi
fi
if [ -x "$NA_BIN" ]; then
  pkill -f 'easystream serve' 2>/dev/null || true
  # The daemon MUST run inside docker's Aqua GUI session: screen capture is only
  # permitted for processes in the logged-in session. A daemon started from the
  # root/launchd context captures nothing but the wallpaper + menu bar (the
  # classic "no Screen Recording permission" symptom = a black/blank stream).
  # A per-user LaunchAgent (LimitLoadToSessionType=Aqua) is the reliable way.
  if [ "$(id -un)" = "root" ]; then
    mkdir -p "$WROOT/Library/LaunchAgents"
    cat > "$WROOT/Library/LaunchAgents/com.easyworker.easystream.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.easyworker.easystream</string>
    <key>ProgramArguments</key>
    <array><string>/Users/docker/easystream</string><string>serve</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PLIST
    # launchd does NOT inherit this shell's environment, so the control token
    # must be written into the plist itself — otherwise the daemon starts with
    # no token (unauthenticated: anyone who reaches :48079 gets control).
    if [ -n "$EAZYSTREAM_CONTROL_TOKEN" ]; then
      /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" "$WROOT/Library/LaunchAgents/com.easyworker.easystream.plist" 2>/dev/null || true
      /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:EAZYSTREAM_CONTROL_TOKEN string '$EAZYSTREAM_CONTROL_TOKEN'" "$WROOT/Library/LaunchAgents/com.easyworker.easystream.plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:EAZYSTREAM_CONTROL_TOKEN '$EAZYSTREAM_CONTROL_TOKEN'" "$WROOT/Library/LaunchAgents/com.easyworker.easystream.plist"
    fi
    if [ -n "$EAZYSTREAM_VIEW_TOKEN" ]; then
      /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:EAZYSTREAM_VIEW_TOKEN string '$EAZYSTREAM_VIEW_TOKEN'" "$WROOT/Library/LaunchAgents/com.easyworker.easystream.plist" 2>/dev/null || true
    fi
    chown docker:staff "$WROOT/Library/LaunchAgents/com.easyworker.easystream.plist"
    # Grant the screen-capture / accessibility TCC permissions to the daemon's
    # stable path, then restart tccd so it re-reads the db (the daemon is
    # restarted by the kickstart below, so it gets a fresh decision).
    #
    # The daemon must stay UNSIGNED and the rows must carry a NULL csreq
    # (client_type=1 = path). Do NOT add a csreq: tccd then fails with
    # `SecRequirementCreateWithData() fails: -67052` and DENIES the request, so
    # screen capture yields only the wallpaper + window frames (a blank
    # "desktop" with just a menu bar). A NULL csreq + path identity is what the
    # desktop images use and is what actually works.
    codesign --remove-signature "$NA_BIN" 2>/dev/null || true
    for DB in "/Library/Application Support/com.apple.TCC/TCC.db"               "$WROOT/Library/Application Support/com.apple.TCC/TCC.db"; do
      for svc in kTCCServiceScreenRecording kTCCServiceScreenCapture                  kTCCServiceAccessibility kTCCServiceListenEvent                  kTCCServicePostEvent kTCCServiceAppleEvents; do
        sqlite3 "$DB" "INSERT OR REPLACE INTO access(service,client,client_type,auth_value,auth_reason,auth_version,csreq,policy_id,indirect_object_identifier_type,indirect_object_identifier,indirect_object_code_identity,flags,last_modified) VALUES('$svc','$NA_BIN',1,2,4,1,NULL,NULL,0,'UNUSED',NULL,0,strftime('%s','now'));" 2>/dev/null || true
      done
    done
    killall -9 tccd 2>/dev/null || true
  # Disable the Keyboard Setup Assistant. It launches at login and is MODAL:
  # it swallows every keystroke, so the guest looks like "keyboard input does
  # not work" (each character needs two presses to get past the dialog).
  # Pre-setting com.apple.keyboardtype is not sufficient on this image, and SIP
  # is off, so just retire the app. Idempotent (no-op once renamed).
  if [ -d /System/Library/CoreServices/KeyboardSetupAssistant.app ]; then
    mv /System/Library/CoreServices/KeyboardSetupAssistant.app        /System/Library/CoreServices/KeyboardSetupAssistant.app.disabled 2>/dev/null || true
  fi
    # Kick the daemon into the Aqua session. ROOT ONLY: `launchctl asuser`
    # requires root, and running this loop as `docker` blocked oem.sh (and
    # therefore the worker, which oem.sh execs afterwards) for 2 minutes.
    for _ in $(seq 1 60); do
      if launchctl print gui/"${AQUA_UID:-501}" >/dev/null 2>&1; then
        launchctl asuser "${AQUA_UID:-501}" launchctl bootout gui/"${AQUA_UID:-501}"/com.easyworker.easystream 2>/dev/null || true
        launchctl asuser "${AQUA_UID:-501}" launchctl bootstrap gui/"${AQUA_UID:-501}" "$WROOT/Library/LaunchAgents/com.easyworker.easystream.plist" 2>/dev/null || true
        launchctl asuser "${AQUA_UID:-501}" launchctl kickstart -k gui/"${AQUA_UID:-501}"/com.easyworker.easystream 2>/dev/null && break
      fi
      sleep 2
    done
  fi
fi

# --- display resolution -----------------------------------------------------
# NOTE: displayplacer was removed. It was a best-effort resolution setter, but
# the artifact path (displayplacer/1.4.0/displayplacer-darwin-amd64) 404s, so
# the launcher downloaded a 33-byte JSON error body and `displayplacer list`
# aborted the whole script under `set -e`+`pipefail` (exit 127) — the worker
# never started. Resolution is not critical; do NOT reintroduce a hard failure
# here. If a resolution must be forced, bake it into the golden disk's
# WindowServer prefs instead.

# --- install the worker binary (dynamic ONLY, no disk fallback) -------------
# The worker arrives in the /files tar fetched at the top of this script, and is
# installed on every boot, so a worker upgrade never needs a golden rebake. There
# is deliberately no disk fallback: if the payload did not land, retry rather
# than silently run a stale binary.
for _ in $(seq 1 30); do
  if [ -s "$BOOTDIR/easyworker" ] \
     && [ "$(stat -f%z "$BOOTDIR/easyworker" 2>/dev/null || echo 0)" -gt 1000000 ]; then
    cp -f "$BOOTDIR/easyworker" "$DL" 2>/dev/null || true
    if [ "$(stat -f%z "$DL" 2>/dev/null || echo 0)" -gt 1000000 ]; then
      chmod 755 "$DL"
      mv -f "$DL" "$BIN" 2>/dev/null || BIN="$DL"
      break
    fi
  fi
  rm -f "$DL" 2>/dev/null || true
  sleep 2
done

# --- TCC --------------------------------------------------------------------
# STATIC: the Accessibility / ScreenCapture grants are BAKED into the golden
# disk's TCC.db by guest/bake-hardening.sh (SIP is off, so the db is writable).
# TCC grants are keyed by the STABLE paths (~/easyworker-darwin), so they
# persist across boots and survive worker upgrades — the launcher does NOT
# re-grant every boot. Persistent state takes the static route.

# The daemon path runs as root; hand the workspace + binaries to docker so the
# worker (which runs as docker) can write its sqlite DB.
if [ "$(id -un)" = "root" ]; then
  chown -R docker:staff "$WS" 2>/dev/null || true
  chown docker:staff "$BIN" 2>/dev/null || true
fi

# On-demand toolchains: the guest can only reach the container (host.lan:8090),
# whose nginx bridges /artifacts/ to the in-cluster artifact registry — so the
# worker's installer fetches toolchains through that bridge.
# The guest reaches the in-cluster artifact registry DIRECTLY (qemu NAT inherits
# the pod's cluster network) — no container bridge needed.
export WORKER_TOOLCHAIN_INDEX="http://artifact.worker.svc.cluster.local/artifacts/generic/toolchains/index/index.json"

# Agent path: already inside docker's Aqua session.
if [ "$(id -un)" = "docker" ]; then
  # The launch script owns logging (same as Windows' oem.cmd): the LaunchAgent
  # plist sets NO StandardOutPath, so launchd never has to open a log file —
  # which is what produced EX_CONFIG (78) when ws/ was root-owned.
  exec "$BIN" -addr 0.0.0.0:48080 -workspace "$WS" -db "$WS/jobs.db" >>"$WS/easyworker.log" 2>&1
fi

# Daemon path: wait for the logged-in session, then hand off to the agent.
for _ in $(seq 1 150); do
  if launchctl print gui/501 >/dev/null 2>&1; then
    if launchctl asuser 501 launchctl kickstart -k gui/501/com.easyworker.worker 2>/dev/null; then
      exit 0
    fi
  fi
  sleep 2
done

# No GUI session ever appeared: run headless as docker (old behaviour).
# WORKER_OS (computer-use driver) and the streamed screen (/stream/ws) -> the
# control panel's desktop pane) must survive the sudo.
exec sudo -u docker --preserve-env=WORKER_TOKEN,WORKER_OS,,PATH "$BIN" \
  -addr 0.0.0.0:48080 -workspace "$WS" -db "$WS/jobs.db"
