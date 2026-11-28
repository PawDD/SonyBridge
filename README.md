# SonyBridge — WH-1000XM4C fork

An unofficial fork of [AmitRajput-Dev/SonyBridge](https://github.com/AmitRajput-Dev/SonyBridge), focused on WH-1000XM4C support in the native macOS application. It retains the upstream Bluetooth/protocol foundation and credits. It is not an official Sony application or an upstream-approved release.

[![macOS](https://github.com/PawDD/SonyBridge/actions/workflows/xcodebuild.yml/badge.svg)](https://github.com/PawDD/SonyBridge/actions/workflows/xcodebuild.yml)
[![Linux & Windows](https://github.com/PawDD/SonyBridge/actions/workflows/cmake.yml/badge.svg)](https://github.com/PawDD/SonyBridge/actions/workflows/cmake.yml)
[![License: MIT](https://img.shields.io/badge/code-MIT-green)](LICENSE)

## Why I created this fork

I use the **Sony WH-1000XM4C** and wanted to control it from my Mac, but the upstream version I tested did not yet support this new model's control layouts. I created this fork to add the support I needed and share it with other XM4C owners, building on SonyBridge's existing work.

**WH-1000XM4C is a separate model introduced in 2026, not another name for the original WH-1000XM4 from 2020.** Sony describes the XM4C as a refresh based on the XM4's established design, with updated sound tuning and a 10-band equalizer. Its familiar appearance does not mean desktop software can reuse the original XM4's protocol assumptions unchanged. See Sony's [XM4C announcement (September 2026)](https://www.sony.co.uk/presscentre/sony-introduces-wh-1000xm4c-wireless-noise-cancelling-headphones-and-updates-popular-mid-and-entry-level-wireless-headphones-with-wh-ch730n-and-wh-ch530) and [original XM4 announcement (August 2020)](https://www.sony.com.hk/press/pdf/20200807_e.pdf).

Created and maintained by [**@PawDD**](https://github.com/PawDD). The changes and validation below concern this fork; upstream authorship and credits are retained.

## What this fork changes

- Capability-gated XM4C ANC/Ambient commands, including the separate Noise Canceling / Wind Noise Reduction selector.
- Ten-band EQ, device-reported preset IDs and names, and editable Manual / Custom 1 / Custom 2 curves. Edits retain the selected slot; dragging sliders does not repeatedly disable preset buttons.
- Type-1 Speak-to-Chat and its timeout settings, preserving sensitivity and voice-focus settings when changing the timeout.
- Fresh read-back after XM4C setting writes: a Bluetooth ACK is not treated as proof that the headphones applied a change.
- Read-only Bluetooth connection priority and a refreshable headset-reported codec on macOS. This fork does not switch connection priority or force a Mac codec.
- Consistent DSEE indicators in the window and menu-bar panel, plus full click targets for header buttons.
- Improved XM4C multipoint switching and reconnection, a two-slot connected-device panel, and separate status messages for app-control and system Bluetooth connections.

Battery, DSEE, auto power-off and the upstream themes and menu-bar controls remain available where supported. [Technical notes and exact validation limits](docs/WH-1000XM4C.md).

## Validation status

Development observations concern **WH-1000XM4C firmware 1.1.2 on an Apple Silicon Mac**. Basic ANC/Ambient, a Manual EQ band, DSEE, Speak-to-Chat on/off and auto power-off were exercised during development. Six factory EQ presets were checked in a prior clean CI-built application.

**Custom 1/2 persistence, Speak-to-Chat timeout and Wind Noise Reduction still need a complete hardware retest of the current commit.** Their packet handling has automated regression coverage; that is not a claim of hardware verification. Windows and Linux have build/test coverage, but XM4C hardware behaviour and UI parity on those platforms are unverified. The maintainer has tested XM4C multipoint switching, reconnection and control handover with Sound Connect on Android. Experimental playback switching/fixing remains outside the verified scope.

The maintainer has tested the application locally and confirmed installation from a packaged DMG on their Mac. This does not establish compatibility with every firmware or configuration.

## Using SonyBridge with Sound Connect

**WH-1000XM4C supports one active control app at a time.** Connecting Sound Connect on Android disconnects SonyBridge's control session on Mac, and vice versa. Bluetooth audio connections remain active. This behaviour was confirmed on XM4C firmware 1.1.2.

Connect the app you want to use: connecting SonyBridge or Sound Connect transfers the control session from the other app. The power button at the top of SonyBridge disconnects its control session manually. Android can automatically launch Sound Connect when the headset connects, which can also transfer control away from SonyBridge.

With multipoint disabled, the headset has only one Bluetooth device connection. Disconnect that device before connecting the other one; opening a control app alone does not free the occupied Bluetooth slot.

SonyBridge reports a closed control connection separately from a lost system Bluetooth connection. A control-link close event does not identify its cause, so the app does not attribute every closure to Sound Connect.

## Download and install on macOS

**Version 0.4.3 supersedes 0.4.2.** It improves recovery from unresponsive headset control sessions, makes it easier to resume control after using the phone app, and animates equalizer preset transitions. See the [changelog](CHANGELOG.md).

Download **SonyBridge XM4C.dmg** from [this fork's latest release](https://github.com/PawDD/SonyBridge/releases/latest). Use the current macOS release. The filename stays simple; the source revision is recorded inside the app. The upstream Homebrew cask and upstream downloads do not contain this fork's changes.

1. Open the DMG and drag **SonyBridge.app** onto **Applications**.
2. Eject the disk image, then launch SonyBridge from Applications.
3. This application is ad-hoc signed, **not Apple-notarized**. If macOS blocks it, first attempt to launch it, then follow [Apple's instructions](https://support.apple.com/en-us/102445) in **System Settings → Privacy & Security → Open Anyway**, if you trust the source.
4. Allow Bluetooth access when prompted. Connect your headphones in macOS Bluetooth settings, then choose **Connect** in SonyBridge.

No Terminal commands or Homebrew are needed. Existing preferences may survive removal of an earlier app. Hardware validation is limited to the configurations and features documented above.

The macOS installer requires **Xcode with macOS SDK 27.2**. The build rejects a different SDK. [macOS Actions](https://github.com/PawDD/SonyBridge/actions/workflows/xcodebuild.yml) runs regression tests; installer generation and artifact upload are skipped when the runner does not have that SDK. The installer is prepared locally from source with the approved Xcode toolchain when the runner does not have that SDK.

## Build and test

Pair/connect the headphones in macOS Bluetooth settings before connecting in SonyBridge.

### macOS

Use full Xcode with **macOS SDK 27.2**. The application targets macOS 12 or later:

```sh
git clone --recurse-submodules https://github.com/PawDD/SonyBridge.git
cd SonyBridge
sh Client/tests/run-macos.sh
open Client/macos/SonyHeadphonesClient.xcodeproj
```

Select the `SonyHeadphonesClient` scheme and build/run. To build and package the current source revision using the same procedure as CI, run `sh Client/macos/build-release.sh` from a clean checkout with full Xcode selected. The release script builds a universal app for Apple Silicon and Intel, then runs `Client/macos/package-dmg.py` to create **SonyBridge XM4C.dmg** and its SHA-256 checksum. The installer includes license notices and instructions in English and Polish. Packaging checks both architectures, removes debugger entitlement from its ad-hoc signature, verifies unchanged executable code/data and checks the mounted DMG. It does not change the application version. CI only builds an installer when its SDK matches the pin, and does not automatically publish a release.

### Windows / Linux

The inherited CMake client can be built with the platform dependencies described in [upstream's build instructions](https://github.com/AmitRajput-Dev/SonyBridge#-build-from-source). To include the protocol regression suite:

```sh
cmake -S Client -B Client/build -DSONYBRIDGE_BUILD_PROTOCOL_TESTS=ON
cmake --build Client/build --config Release
ctest --test-dir Client/build -C Release --output-on-failure
```

`sh Client/tests/run-portable.sh` runs the C++ protocol/read-back checks with clang++ on supported shell environments.

## Contributing and reporting

For issues specific to this fork, use [this repository's issue tracker](https://github.com/PawDD/SonyBridge/issues). Include model, firmware, operating system, build revision and a concise reproduction. Remove Bluetooth addresses, serial numbers, paired-device names, account information and tokens from diagnostics before sharing them. Do not upload raw Bluetooth captures by default.

This fork is based on upstream v0.4.0 at `d0ecd561ebf6f1cb87ffbf29528107b2221724d5`. An upstream contribution can be proposed separately; creating this fork does not imply maintainer acceptance. See the [contribution scope](docs/PUBLICATION_PLAN.md).

## Credits and license

- [AmitRajput-Dev/SonyBridge](https://github.com/AmitRajput-Dev/SonyBridge) — the direct upstream project, native SwiftUI application and v2 protocol support.
- [Plutoberth/SonyHeadphonesClient](https://github.com/Plutoberth/SonyHeadphonesClient), its authors and contributors — the original client and protocol foundation.
- [semvis123](https://github.com/semvis123) — original macOS port.
- [Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge), [BudsLink](https://github.com/maniacx/BudsLink), [Sony Device Center](https://github.com/marconvcm/sony-device-center) and the public [libmdr protocol reference](https://github.com/mos9527/SonyHeadphonesClient) — protocol references and device reports. Specific references are listed in the technical notes.
- [@PawDD](https://github.com/PawDD) — this fork's XM4C implementation, tests and macOS UI changes.

The code is under the [MIT license](LICENSE); upstream copyright and permission notices are retained. Bundled dependencies retain their own license notices, including Dear ImGui and the Cascadia Code font.

Sony product imagery and trademarks remain Sony's property and are **not licensed under this repository's MIT code license**. The retained XM4C render and its modification are documented in [asset provenance](docs/ASSET_SOURCES.md); no separate redistribution permission is asserted. This project is not affiliated with or endorsed by Sony.
