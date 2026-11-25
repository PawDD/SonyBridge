#!/bin/sh
# Build source and resources together; do not reuse an installed app.
set -eu
cd "$(dirname "$0")/../.."
sh Client/macos/check-sdk.sh
if ! xcodebuild -version >/dev/null 2>&1 ||
   ! xcrun --find ibtool >/dev/null 2>&1 ||
   ! xcrun --find actool >/dev/null 2>&1; then
    echo 'A full Xcode installation with the approved SDK is required for source-built release resources.' >&2
    echo 'Command Line Tools alone can build a local preview, not a public installer.' >&2
    exit 1
fi
if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then
    echo 'Release packaging requires a clean checkout.' >&2
    exit 1
fi
revision=$(git rev-parse HEAD)
derived="$PWD/build/release-$revision"
output="$PWD/dist/$revision"
if [ -e "$derived" ] || [ -e "$output" ]; then
    echo 'Build/output already exists for this revision; use a fresh checkout.' >&2
    exit 1
fi
xcodebuild -project Client/macos/SonyHeadphonesClient.xcodeproj \
    -scheme SonyHeadphonesClient -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$derived" \
    -hideShellScriptEnvironment ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM='' build
python3 Client/macos/package-dmg.py \
    --app "$derived/Build/Products/Release/SonyHeadphonesClient.app" \
    --revision "$revision" --output-dir "$output"
