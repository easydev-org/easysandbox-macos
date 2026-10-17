#!/bin/bash
# Guest-side bake for the macOS image (run as root INSIDE the macOS guest).
#
# Goal: agent-worker runs inside docker's logged-in Aqua session (so GUI apps
# reach WindowServer) and docker may sudo without a password or TTY. The
# launcher boot-fetches the worker from host.lan:8090/worker.
set -Eeuo pipefail

WROOT=/Users/docker
SUDOERS=/etc/sudoers.d/agent-worker
LOADER=$WROOT/bootstrap.sh
DAEMON=/Library/LaunchDaemons/com.agentworker.worker.plist
AGENT=$WROOT/Library/LaunchAgents/com.agentworker.worker.plist

mkdir -p "$WROOT/Library/LaunchAgents" "$WROOT/workspace"
chown docker:staff "$WROOT/workspace" "$WROOT/Library/LaunchAgents"

############ 1. passwordless sudo
cat > "$SUDOERS" <<'EOF'
Defaults:docker !requiretty
Defaults:docker !authenticate
docker ALL=(ALL) NOPASSWD: ALL
EOF
chown root:wheel "$SUDOERS"; chmod 440 "$SUDOERS"
visudo -c -f "$SUDOERS"

############ 2. loader (the ONLY launch file on the golden disk)
# It pulls the real logic from the container (host.lan:8090/oem.sh) and runs it,
# so any launch change is an image change — never a golden rebake.
if [ -f /tmp/bootstrap.sh ]; then
  install -m 755 -o root -g wheel /tmp/bootstrap.sh "$LOADER"
fi
chown root:wheel "$LOADER"; chmod 755 "$LOADER"

############ 3. LaunchDaemon: one-shot bootstrap/fallback (not KeepAlive)
cat > "$DAEMON" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.agentworker.worker</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Users/docker/bootstrap.sh</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
</dict>
</plist>
EOF
chown root:wheel "$DAEMON"; chmod 644 "$DAEMON"

############ 4. LaunchAgent: the worker itself, inside docker's Aqua session
cat > "$AGENT" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.agentworker.worker</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Users/docker/bootstrap.sh</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
EOF
chown docker:staff "$AGENT"; chmod 644 "$AGENT"

# NOTE: the easystream daemon's LaunchAgent (com.agentworker.easystream) and its
# screen-capture TCC grants are created by oem.sh at boot, NOT here: they are
# launch logic (a boot change must be an image change, never a golden rebake).

############ 5. auto-login docker so a real GUI session exists at boot
sysadminctl -autologin set -userName docker -password admin \
  -adminUser docker -adminPassword admin 2>&1 | tail -2 || true
defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser -string docker 2>/dev/null || true

############ 5b. BlackHole: the system-audio loopback device
# The easystream daemon captures SYSTEM audio through a HAL loopback device
# (see easystream EST.md): ScreenCaptureKit's capturesAudio does not work in a
# VM. BlackHole is a signed HAL plug-in, so it must be installed HERE, into the
# golden disk — it cannot be installed per boot (coreaudiod would need a
# restart, and the plug-in is signed).
#
# Best-effort: if the download fails the disk still bakes, and the daemon simply
# advertises hasAudio=0.
BLACKHOLE_PKG_URL="${BLACKHOLE_PKG_URL:-https://existential.audio/downloads/BlackHole2ch.pkg}"
if [ ! -d /Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver ]; then
  echo "== 5b. install BlackHole (system-audio loopback) =="
  if curl -fsSL -m 120 -o /tmp/blackhole.pkg "$BLACKHOLE_PKG_URL"; then
    installer -pkg /tmp/blackhole.pkg -target / 2>&1 | tail -2 || true
    rm -f /tmp/blackhole.pkg
    # coreaudiod picks the new plug-in up on restart; the guest reboots after
    # the bake anyway.
    killall coreaudiod 2>/dev/null || true
  else
    echo "WARN: could not download BlackHole from $BLACKHOLE_PKG_URL" >&2
  fi
else
  echo "== 5b. BlackHole already present =="
fi
ls -d /Library/Audio/Plug-Ins/HAL/BlackHole*.driver 2>/dev/null || echo "WARN: no BlackHole driver installed"

############ 6. verify
echo "== sudoers =="; visudo -c -f "$SUDOERS"
echo "== autologin =="; sysadminctl -autologin status 2>&1 | tail -1
echo "== daemon =="; plutil -lint "$DAEMON"
echo "== agent =="; plutil -lint "$AGENT"
echo "== loader =="; ls -la "$LOADER"
echo BAKE_GUEST_OK
