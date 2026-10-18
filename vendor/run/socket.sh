#!/usr/bin/env bash
# status-ws: stream /run/shm/msg.html changes to the status websocket.
set -Eeuo pipefail
path="/run/shm/msg.html"; dir=$(dirname -- "$path"); name=$(basename -- "$path")
lastmsg=""
refresh() {
  [ -s "$path" ] || return 0
  msg=$(< "$path"); msg="${msg%$'\n'}"
  [ -z "$msg" ] || [ "$msg" = "$lastmsg" ] && return 0
  lastmsg="$msg"; echo "s: $msg"
}
refresh
inotifywait -m -q -e close_write,moved_to,delete --format '%e %f' "$dir" |
while read -r event file; do
  [ "$file" = "$name" ] || continue
  case "${event,,}" in delete*) echo "c: vnc" ;; close_write*|moved_to*) refresh ;; esac
done
