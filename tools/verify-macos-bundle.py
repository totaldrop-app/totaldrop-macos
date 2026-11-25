#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
# SPDX-License-Identifier: GPL-3.0-or-later

"""Verifier for assembled TotalDrop.app bundles and .dmg outputs on macOS.

Validates:
  - TotalDrop.app bundle structure (`Contents/Info.plist`, `PkgInfo`, `MacOS/TotalDropMac`,
    `Resources/AppIcon.icns`, `Resources/Localizable.xcstrings`,
    `Resources/apple-app-site-association`, `PlugIns/FinderShareExtension.appex`)
  - Info.plist keys (`CFBundleIdentifier`, `CFBundleShortVersionString`, strictly numeric
    `CFBundleVersion`, `CFBundleIconFile`, `LSMinimumSystemVersion`, `CFBundleURLTypes`)
  - AppIcon.icns header magic and all 7 required PNG sizes (16..1024)
  - Localizable.xcstrings 35-locale parity
  - On macOS (`--check-native`): Mach-O architecture slices (`lipo -archs`),
    non-system dylib hygiene (`otool -L`), and strict ad-hoc/Developer ID `codesign --verify`
  - Optional `.dmg` + `SHA256SUMS` verification (`--dmg <path>`)
  - `--self-test` synthetic bundle validation for Linux static CI checks.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
REQUIRED_ICNS_SLOTS: tuple[tuple[bytes, int], ...] = (
    (b"icp4", 16),
    (b"icp5", 32),
    (b"icp6", 64),
    (b"ic07", 128),
    (b"ic08", 256),
    (b"ic09", 512),
    (b"ic10", 1024),
)


def verify_icns(icns_path: Path) -> None:
    data = icns_path.read_bytes()
    if len(data) < 8 or data[:4] != b"icns":
        raise ValueError(f"{icns_path}: invalid icns magic")
    total_len = struct.unpack(">I", data[4:8])[0]
    if total_len != len(data):
        raise ValueError(f"{icns_path}: length mismatch ({total_len} != {len(data)})")
    pos = 8
    found: dict[bytes, tuple[int, int]] = {}
    while pos < len(data):
        ostype = data[pos : pos + 4]
        clen = struct.unpack(">I", data[pos + 4 : pos + 8])[0]
        if clen < 8 or pos + clen > len(data):
            raise ValueError(f"{icns_path}: invalid chunk length {clen}")
        payload = data[pos + 8 : pos + clen]
        if payload.startswith(PNG_SIGNATURE) and len(payload) >= 24:
            found[ostype] = struct.unpack(">II", payload[16:24])
        pos += clen
    for ostype, expected in REQUIRED_ICNS_SLOTS:
        if found.get(ostype) != (expected, expected):
            raise ValueError(
                f"{icns_path}: slot {ostype.decode('ascii')}={found.get(ostype)} != {(expected, expected)}"
            )


def verify_bundle(
    app_bundle: Path,
    expected_version: str,
    expected_build: str,
    expected_arch: str | None = None,
    check_native: bool = False,
) -> None:
    contents = app_bundle / "Contents"
    info_plist_path = contents / "Info.plist"
    exe_path = contents / "MacOS" / "TotalDropMac"
    pkg_info_path = contents / "PkgInfo"
    icns_path = contents / "Resources" / "AppIcon.icns"
    xcstrings_path = contents / "Resources" / "Localizable.xcstrings"
    aasa_path = contents / "Resources" / "apple-app-site-association"
    ext_plist_path = contents / "PlugIns" / "FinderShareExtension.appex" / "Contents" / "Info.plist"

    for req in (
        info_plist_path,
        exe_path,
        pkg_info_path,
        icns_path,
        xcstrings_path,
        aasa_path,
        ext_plist_path,
    ):
        if not req.is_file() or req.stat().st_size == 0:
            raise ValueError(f"missing or empty bundle component: {req}")

    if pkg_info_path.read_text(encoding="utf-8").strip() != "APPL????":
        raise ValueError("PkgInfo must contain APPL????")

    plist = plistlib.loads(info_plist_path.read_bytes())
    if plist.get("CFBundleIdentifier") != "app.totaldrop.mac":
        raise ValueError(f"unexpected CFBundleIdentifier: {plist.get('CFBundleIdentifier')!r}")
    if plist.get("CFBundleExecutable") != "TotalDropMac":
        raise ValueError(f"unexpected CFBundleExecutable: {plist.get('CFBundleExecutable')!r}")
    if plist.get("CFBundleShortVersionString") != expected_version:
        raise ValueError(
            f"CFBundleShortVersionString {plist.get('CFBundleShortVersionString')!r} != {expected_version!r}"
        )
    bundle_ver = str(plist.get("CFBundleVersion", ""))
    if bundle_ver != expected_build or not bundle_ver.isdigit():
        raise ValueError(f"CFBundleVersion must be numeric {expected_build!r}, got {bundle_ver!r}")
    if plist.get("CFBundleIconFile") != "AppIcon":
        raise ValueError(f"CFBundleIconFile must be 'AppIcon', got {plist.get('CFBundleIconFile')!r}")
    if plist.get("LSMinimumSystemVersion") != "15.0":
        raise ValueError(f"LSMinimumSystemVersion must be '15.0', got {plist.get('LSMinimumSystemVersion')!r}")

    url_types = plist.get("CFBundleURLTypes") or []
    schemes = [s for ut in url_types for s in ut.get("CFBundleURLSchemes", [])]
    if "totaldrop" not in schemes:
        raise ValueError("Info.plist missing totaldrop:// URL scheme")

    ext_plist = plistlib.loads(ext_plist_path.read_bytes())
    if ext_plist.get("CFBundleIdentifier") != "app.totaldrop.mac.FinderShareExtension":
        raise ValueError(f"unexpected extension bundle ID: {ext_plist.get('CFBundleIdentifier')!r}")
    if ext_plist.get("CFBundleShortVersionString") != expected_version:
        raise ValueError("extension CFBundleShortVersionString mismatch")
    if str(ext_plist.get("CFBundleVersion", "")) != expected_build:
        raise ValueError("extension CFBundleVersion mismatch")

    verify_icns(icns_path)

    xc = json.loads(xcstrings_path.read_text(encoding="utf-8"))
    ver_locs = xc.get("strings", {}).get("verificationTitle", {}).get("localizations", {})
    if len(ver_locs) < 35:
        raise ValueError(f"Localizable.xcstrings verificationTitle locales={len(ver_locs)} < 35")

    aasa = json.loads(aasa_path.read_text(encoding="utf-8"))
    app_ids = aasa.get("applinks", {}).get("details", [{}])[0].get("appIDs", [])
    if not any(aid.endswith(".app.totaldrop.mac") for aid in app_ids):
        raise ValueError("apple-app-site-association missing app.totaldrop.mac")

    if check_native:
        lipo_out = subprocess.check_output(["lipo", "-archs", str(exe_path)], text=True).strip()
        archs = set(lipo_out.split())
        if expected_arch == "universal":
            if archs != {"arm64", "x86_64"}:
                raise ValueError(f"expected universal Mach-O (arm64 x86_64), got {lipo_out!r}")
        elif expected_arch:
            if expected_arch not in archs:
                raise ValueError(f"expected Mach-O arch {expected_arch!r}, got {lipo_out!r}")

        otool_out = subprocess.check_output(["otool", "-L", str(exe_path)], text=True)
        for dep in parse_otool_dependencies(otool_out):
            allowed = (
                dep.startswith("/System/Library/")
                or dep.startswith("/usr/lib/")
                or dep.startswith("@rpath/")
                or dep.startswith("@executable_path/")
            )
            if not allowed:
                raise ValueError(f"non-system dylib dependency leaked into TotalDropMac: {dep}")

        subprocess.run(
            ["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app_bundle)],
            check=True,
        )


def parse_otool_dependencies(otool_output: str) -> list[str]:
    """Extract dylib paths from single-arch or universal (fat) `otool -L` output."""
    deps: list[str] = []
    for raw_line in otool_output.splitlines():
        if not raw_line or not raw_line[0].isspace():
            # Header lines like `<path>:` or `<path> (architecture x86_64):` are unindented.
            continue
        dep = raw_line.strip().split(" ", 1)[0]
        if dep:
            deps.append(dep)
    return deps


def verify_dmg(dmg_path: Path, sums_path: Path | None) -> None:
    if not dmg_path.is_file() or dmg_path.stat().st_size == 0:
        raise ValueError(f"missing or empty DMG: {dmg_path}")
    actual_sha = hashlib.sha256(dmg_path.read_bytes()).hexdigest()
    if sums_path is not None:
        lines = sums_path.read_text(encoding="utf-8").splitlines()
        matched = False
        for line in lines:
            parts = line.strip().split()
            if len(parts) >= 2 and parts[-1] == dmg_path.name:
                if parts[0].lower() != actual_sha:
                    raise ValueError(f"SHA256SUMS mismatch for {dmg_path.name}")
                matched = True
        if not matched:
            raise ValueError(f"SHA256SUMS missing entry for {dmg_path.name}")


def run_self_test() -> None:
    repo = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory() as tmp:
        app = Path(tmp) / "TotalDrop.app"
        (app / "Contents" / "MacOS").mkdir(parents=True)
        (app / "Contents" / "Resources").mkdir(parents=True)
        (app / "Contents" / "PlugIns" / "FinderShareExtension.appex" / "Contents" / "MacOS").mkdir(
            parents=True
        )
        (app / "Contents" / "MacOS" / "TotalDropMac").write_bytes(b"\xcf\xfa\xed\xfe\x00" * 16)
        (app / "Contents" / "PkgInfo").write_text("APPL????\n", encoding="utf-8")

        for src, dst in (
            ("target-arm64/Info.plist", app / "Contents" / "Info.plist"),
            (
                "target-arm64/FinderShareExtension-Info.plist",
                app / "Contents" / "PlugIns" / "FinderShareExtension.appex" / "Contents" / "Info.plist",
            ),
        ):
            raw = (repo / src).read_text(encoding="utf-8")
            dst.write_text(
                raw.replace("@VERSION@", "0.3.0-beta.6").replace("@BUILD_NUMBER@", "6"),
                encoding="utf-8",
            )

        shutil.copyfile(
            repo / "ui-swiftui-macos/Resources/AppIcon.icns",
            app / "Contents" / "Resources" / "AppIcon.icns",
        )
        shutil.copyfile(
            repo / "ui-swiftui-macos/Resources/Localizable.xcstrings",
            app / "Contents" / "Resources" / "Localizable.xcstrings",
        )
        shutil.copyfile(
            repo / "ui-swiftui-macos/apple-app-site-association",
            app / "Contents" / "Resources" / "apple-app-site-association",
        )
        verify_bundle(app, "0.3.0-beta.6", "6", check_native=False)

        # Negative test: non-numeric CFBundleVersion must be rejected.
        bad_plist = app / "Contents" / "Info.plist"
        bad_plist.write_text(
            bad_plist.read_text(encoding="utf-8").replace("<string>6</string>", "<string>0.3.0-beta.6</string>"),
            encoding="utf-8",
        )
        try:
            verify_bundle(app, "0.3.0-beta.6", "6", check_native=False)
        except ValueError:
            pass
        else:
            raise AssertionError("expected non-numeric CFBundleVersion to fail")

        # Regression test: multi-architecture (fat) `otool -L` output contains unindented slice headers.
        fat_otool = (
            "dist/universal/TotalDrop.app/Contents/MacOS/TotalDropMac (architecture arm64):\n"
            "\t/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit (compatibility version 45.0.0)\n"
            "\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n"
            "dist/universal/TotalDrop.app/Contents/MacOS/TotalDropMac (architecture x86_64):\n"
            "\t/System/Library/Frameworks/Security.framework/Versions/A/Security (compatibility version 1.0.0)\n"
        )
        parsed = parse_otool_dependencies(fat_otool)
        assert parsed == [
            "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
            "/usr/lib/libSystem.B.dylib",
            "/System/Library/Frameworks/Security.framework/Versions/A/Security",
        ], f"unexpected parsed otool deps: {parsed!r}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true", help="Run synthetic bundle verification self-test")
    parser.add_argument("--app", type=Path, help="Path to assembled TotalDrop.app")
    parser.add_argument("--version", default="0.3.0-beta.6")
    parser.add_argument("--build-number", default="6")
    parser.add_argument("--arch", choices=("arm64", "x86_64", "universal"), default=None)
    parser.add_argument("--check-native", action="store_true", help="Run macOS lipo, otool, and codesign checks")
    parser.add_argument("--dmg", type=Path, default=None, help="Optional .dmg path to verify")
    parser.add_argument("--sha256sums", type=Path, default=None, help="Optional SHA256SUMS file")
    args = parser.parse_args()

    if args.self_test:
        run_self_test()
        print("verify-macos-bundle self-test OK")
        return 0

    if not args.app:
        parser.error("--app is required unless --self-test is set")

    verify_bundle(
        args.app,
        expected_version=args.version,
        expected_build=args.build_number,
        expected_arch=args.arch,
        check_native=args.check_native,
    )
    if args.dmg is not None:
        verify_dmg(args.dmg, args.sha256sums)
    print(f"macOS bundle verified OK: {args.app} (v{args.version} build {args.build_number})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
