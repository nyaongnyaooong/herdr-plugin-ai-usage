#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
exec sh "$script_dir/run-macos.sh" watch-start
