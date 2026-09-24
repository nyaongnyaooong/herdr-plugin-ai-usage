# AI Usage Herdr plugin

Shows remaining Cursor, ChatGPT, and Claude usage in a Herdr status pane and dashboard. Windows and Linux are supported. Usage snapshots and saved accounts stay in each platform's user data directory.

## Install

```sh
herdr plugin link /path/to/ai-usage
herdr server reload-config
```

Windows needs Python 3.9 or newer. Linux needs Python 3 and a POSIX shell. Herdr starts the usage watcher at startup.

Data is stored under `%APPDATA%\AIUsage` on Windows and `${XDG_DATA_HOME:-~/.local/share}/AIUsage` on Linux. Cursor authentication is read from `%APPDATA%\Cursor\User\globalStorage\state.vscdb` on Windows or `${XDG_CONFIG_HOME:-~/.config}/Cursor/User/globalStorage/state.vscdb` on Linux. Codex and Claude use their standard files under `~/.codex` and `~/.claude`.

## Linux keybinding

```toml
[[keys.command]]
key = "prefix+u"
type = "plugin_action"
command = "ai-usage.open-linux"
description = "AI usage"
```

Reload the server config, then press prefix+u to open the dashboard.

The dashboard supports `r` to refresh, `c`/`g`/`l` to save the active Cursor/ChatGPT/Claude session, number keys to apply saved accounts, `x<number>` to delete an account, `vc`/`vg`/`vl` to toggle visibility, and `q` to close.
