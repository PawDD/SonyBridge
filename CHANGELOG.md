# Changelog

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
