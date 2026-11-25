#!/bin/sh
set -eu
client_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
sh "$client_dir/tests/run-portable.sh"
mac_connector_binary="${TMPDIR:-/tmp}/sonybridge-mac-connector-buffer-tests"
# Offline receive-buffer tests for the macOS connector (no Bluetooth channel is opened).
clang++ -std=c++20 -fobjc-arc -pthread -I"$client_dir" -I"$client_dir/macos" \
    "$client_dir/tests/MacConnectorBufferTests.mm" \
    "$client_dir/macos/MacOSBluetoothConnector.mm" \
    -framework IOBluetooth -framework Foundation \
    -o "$mac_connector_binary"

"$mac_connector_binary"

preset_binary="${TMPDIR:-/tmp}/sonybridge-eq-preset-options-tests"
swiftc "$client_dir/macos/EqualizerPresets.swift" "$client_dir/tests/EQPresetOptionsTests.swift" -o "$preset_binary"
"$preset_binary"

# Manual reconnect must drain old-session work and respect cancellation.
lifecycle_binary="${TMPDIR:-/tmp}/sonybridge-mac-connection-lifecycle-tests"
clang++ -std=c++20 -fobjc-arc -pthread -I"$client_dir" -I"$client_dir/macos" \
    "$client_dir/tests/MacConnectionLifecycleTests.mm" \
    "$client_dir/macos/HeadphonesBridge.mm" "$client_dir/macos/MacOSBluetoothConnector.mm" \
    "$client_dir/Headphones.cpp" "$client_dir/BluetoothWrapper.cpp" \
    "$client_dir/ByteMagic.cpp" "$client_dir/CommandSerializer.cpp" \
    -framework IOBluetooth -framework IOBluetoothUI -framework Cocoa \
    -o "$lifecycle_binary"
"$lifecycle_binary"
