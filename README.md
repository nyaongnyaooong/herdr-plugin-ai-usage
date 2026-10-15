# AI Usage Herdr plugin

Shows remaining Cursor, ChatGPT, and Claude usage in a Herdr status pane and dashboard. Windows, macOS, and Linux are supported. Usage snapshots and saved accounts stay in each platform's user data directory.

## Install

```sh
herdr plugin link /path/to/ai-usage
herdr server reload-config
```

All platforms use the same Python 3.9+ dashboard and usage runner. macOS and Linux also need a POSIX shell. macOS no longer requires a Swift build to run the plugin. Herdr starts the usage watcher at startup.

Data is stored under `%APPDATA%\AIUsage` on Windows, `~/Library/Application Support/AIUsage` on macOS, and `${XDG_DATA_HOME:-~/.local/share}/AIUsage` on Linux. Cursor authentication is read from `%APPDATA%\Cursor\User\globalStorage\state.vscdb` on Windows, `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` on macOS, or `${XDG_CONFIG_HOME:-~/.config}/Cursor/User/globalStorage/state.vscdb` on Linux. On macOS and Linux, if the Cursor editor session is unavailable, the plugin reads the Cursor Agent CLI session from `~/.cursor/auth.json` or `~/.config/cursor/auth.json`. On macOS the CLI stores the login in the keychain item `cursor-access-token` / `cursor-user`, and the account email comes from `~/.cursor/cli-config.json`. Codex uses its standard auth file under `~/.codex`. Claude uses macOS Keychain on macOS, with a credentials-file fallback, and its standard credentials file on other platforms. `CLAUDE_CONFIG_DIR` and `CLAUDE_SECURESTORAGE_CONFIG_DIR` select the Claude credential store.

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

The dashboard uses the same controls on Windows, macOS, and Linux:

- Up/Down (or `k`/`j`): move between provider cards and saved accounts.
- Left/Right (or `h`/`l`): select visibility, save, logout, or account-list buttons.
- Enter or Space: execute the selected action or apply a saved account.
- `d`: remove the selected saved account after confirmation.
- `t`: switch between KST (default) and UTC. The choice is saved and applies to dashboard times and status-pane reset times.
- `r`: refresh usage. `q`, Escape, or Ctrl+C: close the dashboard.

Buttons remain selectable even when no accounts have been saved. Session removal requires confirmation. The Mac upgrade preserves existing snapshots, imports Swift saved-account credentials with a backup, and carries over provider visibility. Old accounts that only contain access tokens may need to be saved again to obtain the full login bundle for switching accounts.

Run `python3 scripts/test_dashboard.py` to check the shared dashboard through a PTY, navigation and actions, platform paths, Mac data migration, and keychain handling with isolated fixture credentials. Run `python3 scripts/test_input.py` for arrow decoding and, when `HERDR_TAB_ID` is set, Herdr socket RPC.
