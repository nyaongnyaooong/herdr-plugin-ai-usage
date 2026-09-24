#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$root"
swift build -c release --product ai-usage-herdr
bin_dir=$(swift build -c release --product ai-usage-herdr --show-bin-path)
mkdir -p "$root/bin"
cp "$bin_dir/ai-usage-herdr" "$root/bin/ai-usage-herdr"
chmod +x "$root/bin/ai-usage-herdr"
codesign --force --sign - "$root/bin/ai-usage-herdr"
