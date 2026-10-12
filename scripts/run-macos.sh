#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$script_dir/.." && pwd)
state=${HERDR_PLUGIN_STATE_DIR:-${XDG_STATE_HOME:-"$HOME/.local/state"}/herdr/plugins/ai-usage}
action=${1:-dashboard}
bin="$root/bin/ai-usage-herdr"

if [ ! -x "$bin" ]; then
    "$root/scripts/build.sh"
fi

if [ "$action" = "watch-start" ]; then
    mkdir -p "$state"
    pid_file="$state/watch.pid"
    if [ -f "$pid_file" ]; then
        old_pid=$(cat "$pid_file" 2>/dev/null || true)
        if printf '%s' "$old_pid" | grep -Eq '^[0-9]+$'; then
            old_command=$(ps -p "$old_pid" -o args= 2>/dev/null || true)
            if printf '%s' "$old_command" | grep -q 'ai-usage-herdr'; then
                kill "$old_pid" 2>/dev/null || true
            fi
        fi
    fi
    nohup "$bin" watch >>"$state/watch.log" 2>&1 </dev/null &
    echo "$!" >"$pid_file"
    exit 0
fi

if [ "$action" = "open" ]; then
    herdr_bin=${HERDR_BIN_PATH:-herdr}
    exec "$herdr_bin" plugin pane open --plugin "${HERDR_PLUGIN_ID:-ai-usage}" --entrypoint dashboard-macos --focus
fi

exec "$bin" "$action"
