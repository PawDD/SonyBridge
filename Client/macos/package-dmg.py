#!/usr/bin/env python3
"""Package a universal macOS source build as a drag-to-Applications DMG."""

import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import struct
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
PACKAGE_NAME = "SonyBridge XM4C.dmg"
SOURCE_URL = "https://github.com/PawDD/SonyBridge"


def run(*args, capture=False):
    return subprocess.run(
        [str(arg) for arg in args], check=True, capture_output=capture
    )


def unsigned_payload(executable, architecture, destination):
    """Compare source and packaged code while allowing embedded re-signing."""
    run("lipo", executable, "-thin", architecture, "-output", destination)
    run("codesign", "--remove-signature", destination)
    data = bytearray(destination.read_bytes())
    if len(data) < 32 or struct.unpack_from("<I", data)[0] != 0xFEEDFACF:
        raise ValueError("Expected a 64-bit little-endian Mach-O executable")
    position = 32
    for _ in range(struct.unpack_from("<I", data, 16)[0]):
        command, size = struct.unpack_from("<II", data, position)
        if size < 8 or position + size > len(data):
            raise ValueError("Invalid Mach-O load command")
        # A different signature can change the virtual reservation for LINKEDIT.
        # The remaining load commands and every byte of unsigned code/data
        # must match, not just the visible executable sections.
        if command == 0x19 and data[position + 8:position + 24].rstrip(b"\0") == b"__LINKEDIT":
            struct.pack_into("<Q", data, position + 32, 0)
        position += size
    return bytes(data)


def verify_entitlements(app):
    result = run("codesign", "-d", "--entitlements", ":-", app, capture=True)
    output = result.stdout + result.stderr
    start = output.index(b"<?xml")
    end = output.index(b"</plist>", start) + len(b"</plist>")
    actual = plistlib.loads(output[start:end])
    expected = plistlib.loads(
        (ROOT / "Client/macos/SonyHeadphonesClient.entitlements").read_bytes()
    )
    if actual != expected or "com.apple.security.get-task-allow" in actual:
        raise ValueError("Packaged entitlements do not match the release policy")


def verify_image(dmg, expected_executable_hash):
    run("hdiutil", "verify", "-quiet", dmg)
    result = run(
        "hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-plist", dmg,
        capture=True,
    )
    entities = plistlib.loads(result.stdout)["system-entities"]
    mount = next(Path(item["mount-point"]) for item in entities if "mount-point" in item)
    try:
        app = mount / "SonyBridge.app"
        run("codesign", "--verify", "--deep", "--strict", app)
        verify_entitlements(app)
        shortcut = mount / "Applications"
        if not shortcut.is_symlink() or shortcut.readlink() != Path("/Applications"):
            raise ValueError("Missing Applications shortcut")
        executable = app / "Contents/MacOS/SonyHeadphonesClient"
        if hashlib.sha256(executable.read_bytes()).hexdigest() != expected_executable_hash:
            raise ValueError("Disk-image executable does not match the packaged app")
        if not (app / "Contents/Resources/Notices/LICENSE.txt").is_file():
            raise ValueError("Missing embedded license")
    finally:
        run("hdiutil", "detach", mount)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="CI/source-built .app")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "dist")
    parser.add_argument("--revision", default=os.environ.get("GITHUB_SHA"))
    args = parser.parse_args()
    source_app = args.app.resolve(strict=True)
    if not source_app.is_dir() or source_app.suffix != ".app":
        parser.error("--app must be an application bundle")
    revision = args.revision or run("git", "-C", ROOT, "rev-parse", "HEAD", capture=True).stdout.decode().strip()
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        parser.error("--revision must be a complete Git commit SHA")
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    dmg = output / PACKAGE_NAME
    checksum = output / (PACKAGE_NAME + ".sha256")
    if dmg.exists() or checksum.exists():
        parser.error("Output already exists; choose an empty output directory")

    run("codesign", "--verify", "--deep", "--strict", source_app)
    source_executable = source_app / "Contents/MacOS/SonyHeadphonesClient"
    architectures = set(run("lipo", "-archs", source_executable, capture=True).stdout.decode().split())
    if not {"arm64", "x86_64"}.issubset(architectures):
        parser.error("The input must contain both arm64 and x86_64")

    with tempfile.TemporaryDirectory(prefix="sonybridge-dmg-") as temporary:
        work = Path(temporary)
        stage = work / "image"
        stage.mkdir()
        app = stage / "SonyBridge.app"
        run("ditto", source_app, app)
        notices = app / "Contents/Resources/Notices"
        notices.mkdir(exist_ok=True)
        for source, name in [
            ("LICENSE", "LICENSE.txt"),
            ("Client/Fonts/FontLicense.txt", "CASCADIA-CODE-LICENSE.txt"),
            ("docs/ASSET_SOURCES.md", "ASSET-SOURCES.txt"),
        ]:
            shutil.copyfile(ROOT / source, notices / name)
        (notices / "BUILD.txt").write_text(
            "SonyBridge XM4C — macOS\n"
            f"Source: {SOURCE_URL}\nCommit: {revision}\n"
            "Packaging adds licenses and replaces the ad-hoc signature without\n"
            "debugger entitlement. Application code is unchanged from the input build.\n"
            "This package is not Apple-notarized.\n",
            encoding="utf-8",
        )
        run(
            "codesign", "--force", "--sign", "-", "--entitlements",
            ROOT / "Client/macos/SonyHeadphonesClient.entitlements", app,
        )
        run("codesign", "--verify", "--deep", "--strict", app)
        verify_entitlements(app)
        executable = app / "Contents/MacOS/SonyHeadphonesClient"
        for architecture in ("arm64", "x86_64"):
            before = unsigned_payload(source_executable, architecture, work / (architecture + "-source"))
            after = unsigned_payload(executable, architecture, work / (architecture + "-packaged"))
            if before != after:
                raise ValueError(f"Packaging changed executable code/data for {architecture}")
        executable_hash = hashlib.sha256(executable.read_bytes()).hexdigest()
        (stage / "Applications").symlink_to("/Applications", target_is_directory=True)
        for name in ("INSTALL.txt", "INSTALACJA.txt"):
            shutil.copyfile(ROOT / "Client/macos/distribution" / name, stage / name)
        # Gatekeeper/quarantine is neither bypassed nor configured by packaging.
        # A normal browser download applies the system's quarantine metadata.
        temporary_dmg = work / PACKAGE_NAME
        run(
            "hdiutil", "create", "-volname", "SonyBridge XM4C",
            "-srcfolder", stage, "-format", "UDZO", "-fs", "HFS+", temporary_dmg,
        )
        verify_image(temporary_dmg, executable_hash)
        shutil.copyfile(temporary_dmg, dmg)
    checksum.write_text(
        hashlib.sha256(dmg.read_bytes()).hexdigest() + "  " + dmg.name + "\n",
        encoding="utf-8",
    )
    print(f"Verified package: {dmg}")
    print(f"Checksum: {checksum}")


if __name__ == "__main__":
    main()
