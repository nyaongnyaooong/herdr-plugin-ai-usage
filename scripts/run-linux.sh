#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=${HERDR_PLUGIN_ROOT:-$(dirname -- "$script_dir")}
script="$root/scripts/ai-usage.py"
state=${HERDR_PLUGIN_STATE_DIR:-${XDG_STATE_HOME:-"$HOME/.local/state"}/herdr/plugins/ai-usage}
action=${1:-dashboard}

if [ "$action" = "watch-start" ]; then
    mkdir -p "$state"
    pid_file="$state/watch.pid"
    if [ -f "$pid_file" ]; then
        old_pid=$(cat "$pid_file" 2>/dev/null || true)
        case "$old_pid" in
            ""|*[!0-9]*) ;;
            *)
                old_command=$(ps -p "$old_pid" -o args= 2>/dev/null || true)
                case "$old_command" in
                    *"$script watch"*) kill "$old_pid" 2>/dev/null || true ;;
                esac
                ;;
        esac
    fi
    nohup python3 "$script" watch >>"$state/watch.log" 2>&1 </dev/null &
    echo "$!" >"$pid_file"
    exit 0
fi

exec python3 "$script" "$action"
