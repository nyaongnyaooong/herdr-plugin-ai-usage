# AI Usage Herdr plugin

Shows remaining Cursor, ChatGPT, and Claude usage in a Herdr status pane and dashboard. Windows, macOS, and Linux are supported. Usage snapshots and saved accounts stay in each platform's user data directory.

## Install

```sh
herdr plugin link /path/to/ai-usage
herdr server reload-config
```

Windows needs Python 3.9 or newer. Linux needs Python 3 and a POSIX shell. macOS needs Swift. Herdr starts the usage watcher at startup.

Data is stored under `%APPDATA%\AIUsage` on Windows, `~/Library/Application Support/AIUsage` on macOS, and `${XDG_DATA_HOME:-~/.local/share}/AIUsage` on Linux. Cursor authentication is read from `%APPDATA%\Cursor\User\globalStorage\state.vscdb` on Windows, `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` on macOS, or `${XDG_CONFIG_HOME:-~/.config}/Cursor/User/globalStorage/state.vscdb` on Linux. On macOS and Linux, if the Cursor editor session is unavailable, the plugin reads the Cursor Agent CLI session from `~/.cursor/auth.json` or `~/.config/cursor/auth.json`. On macOS the CLI stores the login in the keychain item `cursor-access-token` / `cursor-user`, and the account email comes from `~/.cursor/cli-config.json`. Codex and Claude use their standard files under `~/.codex` and `~/.claude`.

## macOS keybinding

```toml
[[keys.command]]
key = "prefix+u"
type = "plugin_action"
command = "ai-usage.open-macos"
description = "AI usage"
```

## Linux keybinding

```toml
[[keys.command]]
key = "prefix+u"
type = "plugin_action"
command = "ai-usage.open-linux"
description = "AI usage"
```

On macOS and Linux, the usage watcher adds this `prefix+u` binding to Herdr's `config.toml` when it is missing, then reloads the server config. Press prefix+u to open the dashboard.

The dashboard supports `r` to refresh, `c`/`g`/`l` to save the active Cursor/ChatGPT/Claude session, number keys to apply saved accounts, `x<number>` to delete an account, `vc`/`vg`/`vl` to toggle visibility, and `q` to close.

On macOS, shortcuts respond immediately without Enter. Use Up/Down to select a saved account and Enter to apply it. Numeric account commands (`<number>` and `x<number>`) require Enter so multi-digit account numbers work. Escape cancels a pending command, and Backspace edits it.

Run `sh scripts/test-macos-input.sh` on macOS to verify immediate PTY input, arrow sequences, disabled echo, and terminal restoration. This regression test only needs the Swift compiler, including on Command Line Tools installations without Swift Testing.
