#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
state="${HERDR_PLUGIN_STATE_DIR:-$root/.state}"
mkdir -p "$state"
pidfile="$state/watch.pid"
if [ -f "$pidfile" ]; then
  old=$(cat "$pidfile" 2>/dev/null || true)
  if [ -n "${old}" ] && kill -0 "$old" 2>/dev/null; then
    kill "$old" 2>/dev/null || true
    sleep 0.2
  fi
fi
if [ ! -x "$root/bin/ai-usage-herdr" ]; then
  "$root/scripts/build.sh"
fi
nohup "$root/bin/ai-usage-herdr" watch >>"$state/watch.log" 2>&1 &
echo $! > "$pidfile"
