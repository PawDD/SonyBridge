# Fork and contribution scope

## Repository structure

This is a fork of [AmitRajput-Dev/SonyBridge](https://github.com/AmitRajput-Dev/SonyBridge), based on v0.4.0 at `d0ecd561ebf6f1cb87ffbf29528107b2221724d5`. Upstream history and license notices are preserved. XM4C development commits use the contributor's GitHub noreply identity. A separate private development repository is not made public as part of creating this fork.

A fork is an independent modification, not an official Sony product or evidence of upstream maintainer approval. A pull request or release is a separate action; this preparation does not post messages to the upstream maintainer or publish binaries.

## Proposed upstream contribution

Suggested title: **Add capability-gated WH-1000XM4C controls and device-reported EQ presets**.

Battery/firmware could be read, but XM4C ANC, EQ and Speak-to-Chat used incompatible assumptions. The change selects advertised layouts, includes the extra ANC byte, supports ten raw EQ bands and queries the real preset list. macOS checks fresh read-back before reporting a successful setting change. Custom 1/2 editing, wind reduction and speech timing have fixture coverage and remain explicitly pending a complete current-commit hardware retest.

Keep Windows/Linux hardware support and experimental playback switching/fixing outside the verified claims. XM4C multipoint switching, reconnection and control handover have owner validation on firmware 1.1.2; this is not a claim for every firmware or platform. Connection priority is read-only on macOS, with no exposed priority-write API. Do not describe fixture tests or successful compilation as proof of real-device support.

## Privacy and provenance

Review the contribution against its upstream base, including all added commit metadata and reachable blobs. Exclude local diagnostic/injection libraries, raw Bluetooth/session logs, device addresses, serials, paired-device names, host paths, account data, credentials and signing material. Minimal reconstructed protocol fixtures are sufficient.

Keep the original MIT license, copyright notices, dependency notices and upstream attribution. The XM4C product render is retained separately from the MIT code license, with its source and editing history recorded in [asset provenance](ASSET_SOURCES.md). The project does not assert that Sony granted a redistribution license for this image.

## Validation and release limits

Run the offline regression suite and the full source build with the approved toolchain, including both macOS architectures. CI runs regressions; installer production is gated by the SDK pin. Use [the technical notes](WH-1000XM4C.md) for hardware evidence and outstanding tests. A stable binary release needs a current-commit hardware smoke test; do not package a local diagnostic application as a public release.

CI uploads only selected build artifacts. It does not automatically create a GitHub release or publish a website. Fork CI artifacts can be visible to repository readers; they are not private merely because they came from Actions. Distributables must be built from the reviewed revision using `sh Client/macos/build-release.sh`. Release naming does not expand the hardware validation recorded in the technical notes. Ad-hoc signing is not Apple notarization.

## Current installer procedure

The approved appearance baseline uses macOS SDK 27.2, pinned in `Client/macos/required-sdk.txt`. Both build scripts reject another SDK. The existing `macos-15-intel` runner used SDK 15.5 for 0.4.1 and is incompatible with this baseline; its installer steps are skipped when the SDK differs. Do not publish an artifact from an incompatible toolchain. Select a toolchain with the approved SDK before the next release. A toolchain change requires explicit owner approval after checking sliders, switches and colors in every Appearance theme, during theme changes and after relaunch. Passing compilation and packaging checks does not establish visual equivalence.

For a local preview with the previous build method, run `bash Client/macos/build-local.sh /path/to/reference/SonyBridge.app`. It compiles application code with the pinned SDK and explicitly reuses the reference app's storyboard/icon resources. Its output is marked `0.4.2-local` and must not be published. Public installers still require all resources built from source with full Xcode.

1. Start from a clean checkout of the reviewed commit, select full Xcode, and run `sh Client/tests/run-macos.sh` followed by `sh Client/macos/build-release.sh`. The release command requests both arm64 and x86_64. The existing `macos-15-intel` installer steps are skipped by the SDK check; use the approved local full-Xcode environment until a compatible CI toolchain is explicitly selected and reviewed.
2. Take only `SonyBridge XM4C.dmg` and its checksum from `dist/<full-commit-sha>/` (or the matching successful CI artifact). The script builds application code, storyboard and image catalog together from source; installed apps and previously compiled resources are not inputs.
3. Verify the CI run's source SHA, the packaged `Notices/BUILD.txt`, and the SHA-256 before uploading. Packaging already checks signatures, entitlements, both architectures, executable integrity and the mounted image.
4. For application behaviour changes, increment the application version and publish a new versioned tag/release from the reviewed, successful CI revision (for example `xm4c-macos-v0.4.1`). Do not move an existing published tag or silently replace the older version. Upload the DMG and checksum together; when GitHub normalizes spaces to dots in asset names, make the checksum filename entry match the downloaded DMG name. Mark the new stable release as latest and link to it from the superseded release. Keep its public description focused on user-facing changes and validation limits; private debugging notes and captures stay local.

Documentation, image or packaging maintenance alone does not require an application-version bump. Distinct source commits are recorded in `BUILD.txt`; this does not promise byte-identical DMGs between toolchains or signing operations. Behavioural fixes are released with a new application version; this multipoint maintenance release is 0.4.2.
