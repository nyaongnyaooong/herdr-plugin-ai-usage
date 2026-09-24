#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
herdr="${HERDR_BIN_PATH:-herdr}"
exec "$herdr" plugin pane open --plugin ai-usage --entrypoint dashboard --focus
