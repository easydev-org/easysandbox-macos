#!/bin/bash
# Guest-side hardening for the macOS golden disk (run as root inside the guest).
# Removes the GUI prompts that would otherwise require a human click:
#   * Gatekeeper / quarantine ("unidentified developer", "are you sure?")
#   * TCC consent dialogs (Accessibility / ScreenCapture / Files / Automation)
#   * first-login Setup Assistant panes (keyboard, cloud, Siri, privacy, ...)
#   * stray login items
# Safe to re-run.
set -uo pipefail

WROOT=/Users/docker
TCC="/Library/Application Support/com.apple.TCC/TCC.db"

echo '== 1. Gatekeeper + quarantine off =='
spctl --master-disable 2>/dev/null || true
defaults write /Library/Preferences/com.apple.security GKAutoRearm -bool false 2>/dev/null || true
defaults write com.apple.LaunchServices LSQuarantine -bool false 2>/dev/null || true

echo '== 2. pre-grant TCC (no consent dialogs) =='
# Columns mirror the launcher's grant (auth_value=2 allow, client_type=1 path).
grant() {
  local client="$1" svc="$2"
  sqlite3 "$TCC" "INSERT OR REPLACE INTO access(service,client,client_type,auth_value,auth_reason,auth_version,csreq,policy_id,indirect_object_identifier_type,indirect_object_identifier,indirect_object_code_identity,flags,last_modified) VALUES('$svc','$client',1,2,4,1,NULL,NULL,0,'UNUSED',NULL,0,strftime('%s','now'));" 2>/dev/null || true
}
# Drop stale/obsolete clients from earlier layouts (the a11y helper moved
# into the daemon; old worker names are gone), and clear any csreq an
# earlier bake wrote so every row is the working NULL-csreq form. A
# non-NULL csreq that does not match the (unsigned) binary makes tccd
# fail with SecRequirementCreateWithData (-67052) and DENY the request
# (screen capture then yields only the wallpaper + window frames).
for stale in /usr/local/bin/xa11y "$WROOT/xa11y" "$WROOT/agent-worker-v0.5.2" "$WROOT/easyworker-darwin" "$WROOT/easyworker"; do
  sqlite3 "$TCC" "delete from access where client='$stale';" 2>/dev/null || true
done
sqlite3 "$TCC" "update access set csreq=NULL where csreq IS NOT NULL;" 2>/dev/null || true

for client in \
  "$WROOT/agent-worker-darwin" \
  "$WROOT/agent-worker" \
  "$WROOT/easystream" \
  /bin/bash /bin/zsh /usr/bin/curl /usr/bin/python3 \
  /System/Applications/Utilities/Terminal.app \
  /Applications/Xcode.app ; do
  for svc in \
    kTCCServiceAccessibility \
    kTCCServiceScreenCapture \
    kTCCServiceSystemPolicyAllFiles \
    kTCCServiceAppleEvents \
    kTCCServiceListenEvent \
    kTCCServicePostEvent \
    kTCCServiceScreenRecording ; do
    grant "$client" "$svc"
  done
done

echo '== 3. Setup Assistant: mark everything seen =='
for k in DidSeeKeyboardSetupAssistant DidSeeCloudSetup DidSeeSiriSetup \
         DidSeePrivacy DidSeeAccessibility DidSeeAppearanceSetup \
         DidSeeScreenTime DidSeeTrueTone DidSeeTouchIDSetup ; do
  defaults write com.apple.SetupAssistant "$k" -bool true 2>/dev/null || true
done
# Pre-set the keyboard type so the Keyboard Setup Assistant never appears.
# The assistant is triggered by the USER-domain value being absent (a system
# /Library/Preferences write alone is NOT enough — the KSA reads the user's
# domain). Set it for docker in BOTH the user domain and ByHost.
defaults write /Library/Preferences/com.apple.keyboardtype keyboardtype -int 40 2>/dev/null || true
if id docker >/dev/null 2>&1; then
  sudo -u docker defaults write com.apple.keyboardtype keyboardtype -int 40 2>/dev/null || true
  sudo -u docker defaults -currentHost write com.apple.keyboardtype keyboardtype -int 40 2>/dev/null || true
fi

# Keyboard Setup Assistant (KSA) launches at login and is MODAL: it swallows
# every keystroke, so the guest looks like "keyboard input does not work" (and
# it takes two presses per character to get past it). Pre-setting
# com.apple.keyboardtype is NOT enough on this image, so disable the assistant
# outright. SIP is off in this image, so the system app is writable.
if [ -d /System/Library/CoreServices/KeyboardSetupAssistant.app ]; then
  mv /System/Library/CoreServices/KeyboardSetupAssistant.app      /System/Library/CoreServices/KeyboardSetupAssistant.app.disabled 2>/dev/null || true
fi
echo '== 4. no window restore / no reopen =='
defaults write NSGlobalDomain NSQuitAlwaysKeepsWindows -bool false 2>/dev/null || true
defaults write com.apple.loginwindow TALLogoutSucceeded -bool false 2>/dev/null || true
rm -rf "$WROOT/Library/Saved Application State/"* 2>/dev/null || true

echo '== 5. clear stray login items =='
osascript -e 'tell application "System Events" to delete every login item' 2>/dev/null || true

echo "== 5b. remove legacy / stale files =="
# The a11y helper is gone (its job moved into the easystream daemon), and
# the old worker name is gone too. Clear their sudoers + any stray files.
rm -f /private/etc/sudoers.d/easyworker /private/etc/sudoers.d/xa11y 2>/dev/null || true
rm -f /usr/local/bin/xa11y "$WROOT/xa11y" "$WROOT/agent-worker-v0.5.2" \
      "$WROOT/easyworker" "$WROOT/easyworker-darwin" 2>/dev/null || true

echo '== 6. restart tccd so grants take effect =='
launchctl stop com.apple.tccd 2>/dev/null || true
pkill -9 tccd 2>/dev/null || true

echo 'MAC_HARDENING_OK'

echo '== 7. remove run-time files that must NOT be on the golden disk =='
# The boot path fetches these every boot (image change, never a golden rebake):
#   easystream          <- nginx /easystream
#   agent-worker-darwin <- nginx /worker
#   oem.sh              <- nginx /oem.sh
# The golden disk must carry ONLY the loader (bootstrap.sh) + the LaunchAgents.
# (They appear here because the LaunchAgent runs the loader during baking.)
launchctl bootout system/com.agentworker.worker 2>/dev/null || true
launchctl bootout gui/501/com.agentworker.worker 2>/dev/null || true
launchctl bootout gui/501/com.agentworker.easystream 2>/dev/null || true
sleep 2
pkill -9 -f agent-worker-darwin 2>/dev/null || true
pkill -9 -f 'easystream serve' 2>/dev/null || true
sleep 1
rm -f "$WROOT/easystream" "$WROOT/easystream.dl" \
      "$WROOT/agent-worker-darwin" "$WROOT/agent-worker-darwin.dl" \
      "$WROOT/oem.sh" 2>/dev/null || true
rm -rf "$WROOT/workspace" "$WROOT/ws" 2>/dev/null || true
rm -f /Library/Logs/agent-worker.log 2>/dev/null || true
echo '== 8. final: /Users/docker (ours) =='
ls -la "$WROOT" | grep -vE '^total|Desktop|Documents|Downloads|Library|Movies|Music|Pictures|Public|Trash|CFUser|^d.*\.$|^d.*\.\.$' || true
