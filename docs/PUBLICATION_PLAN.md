# Fork and contribution scope

## Repository structure

This is a fork of [AmitRajput-Dev/SonyBridge](https://github.com/AmitRajput-Dev/SonyBridge), based on v0.4.0 at `d0ecd561ebf6f1cb87ffbf29528107b2221724d5`. Upstream history and license notices are preserved. XM4C development commits use the contributor's GitHub noreply identity. A separate private development repository is not made public as part of creating this fork.

A fork is an independent modification, not an official Sony product or evidence of upstream maintainer approval. A pull request or release is a separate action; this preparation does not post messages to the upstream maintainer or publish binaries.

## Proposed upstream contribution

Suggested title: **Add capability-gated WH-1000XM4C controls and device-reported EQ presets**.

Battery/firmware could be read, but XM4C ANC, EQ and Speak-to-Chat used incompatible assumptions. The change selects advertised layouts, includes the extra ANC byte, supports ten raw EQ bands and queries the real preset list. macOS checks fresh read-back before reporting a successful setting change. Custom 1/2 editing, wind reduction and speech timing have fixture coverage and remain explicitly pending a complete current-commit hardware retest.

Keep Windows/Linux hardware support and multipoint outside the verified claims. Connection priority is read-only on macOS, with no exposed priority-write API. Do not describe fixture tests or successful compilation as proof of real-device support.

## Privacy and provenance

Review the contribution against its upstream base, including all added commit metadata and reachable blobs. Exclude local diagnostic/injection libraries, raw Bluetooth/session logs, device addresses, serials, paired-device names, host paths, account data, credentials and signing material. Minimal reconstructed protocol fixtures are sufficient.

Keep the original MIT license, copyright notices, dependency notices and upstream attribution. The XM4C product render is retained separately from the MIT code license, with its source and editing history recorded in [asset provenance](ASSET_SOURCES.md). The project does not assert that Sony granted a redistribution license for this image.

## Validation and release limits

Run the offline regression suite and full source build in CI, including both macOS architectures. Use [the technical notes](WH-1000XM4C.md) for hardware evidence and outstanding tests. A stable binary release needs a current-commit hardware smoke test; do not package a local diagnostic application as a public release.

CI uploads only selected build artifacts. It does not automatically create a GitHub release or publish a website. Fork CI artifacts can be visible to repository readers; they are not private merely because they came from Actions. Any future distributable must be rebuilt from the reviewed revision and identified honestly as development, prerelease or stable. Ad-hoc signing is not Apple notarization.
