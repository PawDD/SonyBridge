#!/bin/bash
set -euo pipefail
# Local preview only: compiled storyboard/icon resources are supplied explicitly.
# Public releases must use build-release.sh and compile resources from source.
if [ "$#" -ne 1 ]; then
  echo "Usage: bash Client/macos/build-local.sh /path/to/reference/SonyBridge.app" >&2
  exit 1
fi
export SONYBRIDGE_REFERENCE_APP="$(cd "$1" && pwd)"
cd "$(dirname "$0")/../.."
sh Client/macos/check-sdk.sh
root="$PWD"
build="$root/build/local-preview"
rm -rf "$build"
mkdir -p "$build"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
for arch in arm64; do
  obj="$build/$arch"
  mkdir -p "$obj"
  target="$arch-apple-macosx12.0"
  xcrun swiftc -parse-as-library -whole-module-optimization -O -swift-version 5 \
    -sdk "$sdk" -target "$target" -module-name SonyHeadphonesClient \
    -import-objc-header Client/macos/SonyHeadphonesClient-Bridging-Header.h \
    -emit-module-path "$obj/SonyHeadphonesClient.swiftmodule" \
    -emit-objc-header-path "$obj/SonyHeadphonesClient-Swift.h" \
    -emit-object Client/macos/ContentView.swift Client/macos/HeadphonesModel.swift \
    Client/macos/Theme.swift Client/macos/MenuBarController.swift \
    Client/macos/QuickControlsView.swift Client/macos/EqualizerPresets.swift -o "$obj/SwiftUI.o"
  objects=("$obj/SwiftUI.o")
  for source in Client/BluetoothWrapper.cpp Client/ByteMagic.cpp Client/CommandSerializer.cpp Client/TimedMessageQueue.cpp Client/Headphones.cpp Client/macos/main.mm Client/macos/MacOSBluetoothConnector.mm Client/macos/HeadphonesBridge.mm Client/macos/AppDelegate.mm Client/macos/ViewController.mm; do
    object="$obj/$(basename "$source").o"
    flags=(-DNDEBUG)
    if [[ "$source" == *.mm ]]; then flags+=(-fobjc-arc); fi
    xcrun clang++ -std=c++20 -O2 -target "$target" -isysroot "$sdk" \
      -IClient -IClient/macos -I"$obj" "${flags[@]}" -c "$source" -o "$object"
    objects+=("$object")
  done
  xcrun swiftc -sdk "$sdk" -target "$target" "${objects[@]}" \
    -lc++ -framework SwiftUI -framework Cocoa -framework IOBluetooth -framework IOBluetoothUI \
    -o "$obj/SonyHeadphonesClient"
  echo "Compiled $arch"
done
python3 - <<'PY'
from pathlib import Path
import shutil,plistlib,json,os,subprocess
root=Path.cwd();app=root/'build/local-preview/SonyBridge.app';res=app/'Contents/Resources';exe=app/'Contents/MacOS'
res.mkdir(parents=True,exist_ok=True);exe.mkdir(parents=True,exist_ok=True)
archive=Path(os.environ['SONYBRIDGE_REFERENCE_APP'])/'Contents/Resources'
shutil.copytree(archive/'Main.storyboardc',res/'Main.storyboardc',dirs_exist_ok=True)
icons=list(archive.glob('*.icns'))
if icons: shutil.copy2(icons[0],res/'AppIcon.icns')
for folder in (root/'Client/macos/Assets.xcassets').glob('*.imageset'):
 for item in json.loads((folder/'Contents.json').read_text())['images']:
  if 'filename' in item:
   src=folder/item['filename'];shutil.copy2(src,res/(folder.stem+src.suffix));break
info=plistlib.loads((root/'Client/macos/info.plist').read_bytes());info['CFBundleIconFile']='AppIcon';info['LSMinimumSystemVersion']='12.0'
info['CFBundleShortVersionString']='0.4.2-local'
info['CFBundleVersion']='0.4.2'
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
(res/'LOCAL-BUILD.txt').write_text(
 'Local preview; not a release. Compiled reference resources reused.\n'
 + 'SDK: '+subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-version'],text=True)
 + subprocess.check_output(['xcrun','swiftc','--version'],text=True)
 + 'Base revision: '+subprocess.check_output(['git','rev-parse','HEAD'],text=True)
 + 'Includes local source changes.\n')
PY
app="$build/SonyBridge.app"
cp "$build/arm64/SonyHeadphonesClient" "$app/Contents/MacOS/SonyHeadphonesClient"
codesign --force --sign - --entitlements Client/macos/SonyHeadphonesClient.entitlements "$app"
codesign --verify --deep --strict "$app"
