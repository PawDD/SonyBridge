# Changelog

## 0.4.3 — 2026-11-28

- Check control-session responsiveness using matched basic inquiry replies rather than the open RFCOMM channel alone. Pause controls while checking; release the session after three consecutive failed heartbeat attempts. A successful basic reply clears the failure count, and optional feature failures do not disconnect the session.
- Prevent overlapping periodic refreshes, cancel queued work from disconnected sessions, discard their late results, and reset pending UI operations on disconnect.
- Restore an explicit “Release control to phone” action in the window, quick controls and menu. Resuming uses a fresh connection to the same headset. After a control-channel close, or a response timeout while Bluetooth remains connected, try once to restore control. Failed settings are not replayed.
- Retry unavailable v2 device lists less frequently while basic control remains responsive. Connection guidance applies to Android and iPhone.

Covered by offline protocol/session-health and macOS queue lifecycle tests. The maintainer reports that the current application has been tested and works; this does not establish compatibility with every firmware or platform, and no iOS handover compatibility claim is made.

## 0.4.2 — 2026-11-25

Maintenance update superseding 0.4.1.

- Restore the macOS SDK 27.2 appearance baseline and reject builds with a different SDK. Record SDK, compiler and Xcode versions in package metadata.
- Enable required session alerts before XM4C multipoint changes, fixing timeouts in fresh sessions.
- Reconnect once and verify the actual multipoint setting when the headset restarts before acknowledging the confirmation; never resend the setting during recovery.
- Drain old control-session work before every connection attempt and respect cancellation while waiting for the queue.
- Align the multipoint switch with other switches and place refresh beside the expanded “Connected devices” heading, with a consistent button style.
- Remove the redundant phone-control action and experimental footer from the multipoint panel. Move “Copy diagnostics” to the device information popover and retain access after a connection error.
- Keep the last multipoint attempt locally across application restarts, and clarify Bluetooth timeout and disconnection messages.

Controlled hardware checks covered multipoint changes and control handover on XM4C firmware 1.1.2 with an Apple Silicon Mac. Missing-confirmation-ACK recovery also has automated regression coverage. This is not a claim that all firmware, idle power-off edge cases or experimental playback controls are verified.

The universal macOS installer is built from source with Xcode 27.2 and macOS SDK 27.2.

## 0.4.1 — 2026-11-25

Recommended maintenance update for WH-1000XM4C users.

- Improve multipoint switching and reconnect to the same headset after its connection restarts.
- Read back the actual multipoint setting after reconnecting instead of treating a Bluetooth acknowledgement as proof of application.
- Show two numbered connection slots, with “Not connected” for an empty slot. Keep the panel together with the multipoint switch at the bottom of the window.
- Correct device-list parsing when a disconnected remembered device has a placeholder name.
- Distinguish a closed app-control connection from a lost system Bluetooth connection, and provide a clear handover action for Sound Connect.
- Improve connection setup errors and cancellation of pending Bluetooth reads.

WH-1000XM4C supports one active control app at a time. Connecting Sound Connect on Android disconnects SonyBridge's control session on Mac, and vice versa; Bluetooth audio connections remain active. This behaviour was confirmed on firmware 1.1.2.

Hardware validation is limited to the maintainer's XM4C configuration. Other firmware and platforms, and experimental playback switching/fixing, are not covered by that validation. See the [technical notes](docs/WH-1000XM4C.md).
