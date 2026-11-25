#!/bin/sh
# SDK changes require an explicit review of native control appearance.
set -eu
script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
expected=$(cat "$script_dir/required-sdk.txt")
actual=$(xcrun --sdk macosx --show-sdk-version)
if [ "$actual" != "$expected" ]; then
    echo "macOS SDK mismatch: expected $expected, selected $actual." >&2
    echo "Select the approved toolchain; do not change the SDK pin without appearance review." >&2
    exit 1
fi
printf 'Verified macOS SDK %s\n' "$actual"
