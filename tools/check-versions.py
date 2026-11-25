#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
# SPDX-License-Identifier: GPL-3.0-or-later

"""Version, C header, runner-pin, and packaging parity guard for totaldrop-macos.

Enforces single-source parity across:
  - crates/totaldrop-macos-ffi/Cargo.toml (`APP_VERSION`) and `src/lib.rs` (`BUNDLE_VERSION`)
  - crates/totaldrop-macos-ffi/include/totaldrop_macos_ffi.h == ui-swiftui-macos/Sources/CTotalDropMacFFI/include/totaldrop_macos_ffi.h
  - target-arm64/Info.plist & target-arm64/FinderShareExtension-Info.plist placeholders
  - target-arm64/{build.sh,create-dmg.sh,Casks/totaldrop.rb}
  - target-x86_64/{build.sh,create-dmg.sh,Casks/totaldrop.rb}
  - all 6 subplatforms/*/*/{RECIPE.toml,build.sh,verify.sh}
  - .github/workflows/ci.yml & all 6 .github/workflows/pkg-*.yml (ADR 0009 pinned macos-15)
"""

from __future__ import annotations

import re
import sys
import tomllib
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

EXPECTED_APP_VERSION = "0.3.0-beta.6"
EXPECTED_BUILD_NUMBER = "6"
EXPECTED_CORE_VERSION = "0.2.0-beta.5"
EXPECTED_MACOS_RUNNER = "macos-15"


def fail(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def check_contains(rel_path: str, needle: str, label: str) -> None:
    p = REPO_ROOT / rel_path
    if not p.is_file():
        fail(f"missing {rel_path}")
    text = p.read_text(encoding="utf-8")
    if needle not in text:
        fail(f"{rel_path}: expected {label} ({needle!r})")


def main() -> int:
    # 1. Rust FFI crate version & monotonic numeric CFBundleVersion
    ffi_toml = tomllib.loads(
        (REPO_ROOT / "crates/totaldrop-macos-ffi/Cargo.toml").read_text(encoding="utf-8")
    )
    if ffi_toml["package"]["version"] != EXPECTED_APP_VERSION:
        fail(
            f"crates/totaldrop-macos-ffi/Cargo.toml version {ffi_toml['package']['version']!r} "
            f"!= {EXPECTED_APP_VERSION!r}"
        )

    ws_toml = tomllib.loads((REPO_ROOT / "Cargo.toml").read_text(encoding="utf-8"))
    if ws_toml["workspace"]["package"]["version"] != EXPECTED_CORE_VERSION:
        fail(
            f"Cargo.toml workspace version {ws_toml['workspace']['package']['version']!r} "
            f"!= {EXPECTED_CORE_VERSION!r}"
        )

    lib_rs = (REPO_ROOT / "crates/totaldrop-macos-ffi/src/lib.rs").read_text(encoding="utf-8")
    m_bundle = re.search(r'pub const BUNDLE_VERSION: &str = "([^"]+)";', lib_rs)
    if not m_bundle or m_bundle.group(1) != EXPECTED_BUILD_NUMBER:
        fail(f"crates/totaldrop-macos-ffi/src/lib.rs BUNDLE_VERSION != {EXPECTED_BUILD_NUMBER!r}")
    if not m_bundle.group(1).isdigit():
        fail("BUNDLE_VERSION must be strictly numeric for Apple CFBundleVersion")

    m_core = re.search(r'pub const CORE_VERSION: &str = "([^"]+)";', lib_rs)
    if not m_core or m_core.group(1) != EXPECTED_CORE_VERSION:
        fail(f"crates/totaldrop-macos-ffi/src/lib.rs CORE_VERSION != {EXPECTED_CORE_VERSION!r}")

    # 2. C ABI header parity between Rust crate and SwiftPM C module
    rust_hdr = REPO_ROOT / "crates/totaldrop-macos-ffi/include/totaldrop_macos_ffi.h"
    swift_hdr = REPO_ROOT / "ui-swiftui-macos/Sources/CTotalDropMacFFI/include/totaldrop_macos_ffi.h"
    if not rust_hdr.is_file() or not swift_hdr.is_file():
        fail("missing totaldrop_macos_ffi.h in Rust crate or SwiftPM CTotalDropMacFFI")
    if rust_hdr.read_bytes() != swift_hdr.read_bytes():
        fail("totaldrop_macos_ffi.h drifted between crates/totaldrop-macos-ffi and ui-swiftui-macos")

    # 3. Info.plist & FinderShareExtension-Info.plist separate short version vs numeric build
    for plist_rel in ("target-arm64/Info.plist", "target-arm64/FinderShareExtension-Info.plist"):
        check_contains(plist_rel, "<string>@VERSION@</string>", "@VERSION@ placeholder")
        check_contains(plist_rel, "<string>@BUILD_NUMBER@</string>", "@BUILD_NUMBER@ placeholder")

    # 4. Target build, DMG, and Homebrew Cask scripts
    for script_rel in (
        "target-arm64/build.sh",
        "target-arm64/create-dmg.sh",
        "target-x86_64/build.sh",
        "target-x86_64/create-dmg.sh",
    ):
        check_contains(
            script_rel,
            f'TOTALDROP_VERSION:-{EXPECTED_APP_VERSION}',
            f"default app version {EXPECTED_APP_VERSION}",
        )
    for build_rel in ("target-arm64/build.sh", "target-x86_64/build.sh"):
        check_contains(
            build_rel,
            f'TOTALDROP_BUILD_NUMBER:-{EXPECTED_BUILD_NUMBER}',
            f"default build number {EXPECTED_BUILD_NUMBER}",
        )
        check_contains(build_rel, "totaldrop-macos-ffi", "Rust FFI staticlib package")

    for cask_rel in ("target-arm64/Casks/totaldrop.rb", "target-x86_64/Casks/totaldrop.rb"):
        check_contains(cask_rel, f'version "{EXPECTED_APP_VERSION}"', f"cask version {EXPECTED_APP_VERSION}")

    # 5. All 6 subplatform units & workflows pinned to EXPECTED_APP_VERSION and macos-15 (ADR 0009)
    recipes = sorted((REPO_ROOT / "subplatforms").glob("*/*/RECIPE.toml"))
    if len(recipes) != 6:
        fail(f"expected 6 subplatform recipes, found {len(recipes)}")
    for recipe in recipes:
        data = tomllib.loads(recipe.read_text(encoding="utf-8"))
        if data["version"] != EXPECTED_APP_VERSION:
            fail(f"{recipe.relative_to(REPO_ROOT)}: version {data['version']!r} != {EXPECTED_APP_VERSION!r}")
        if data["runner"] != EXPECTED_MACOS_RUNNER:
            fail(f"{recipe.relative_to(REPO_ROOT)}: runner {data['runner']!r} != {EXPECTED_MACOS_RUNNER!r}")
        if EXPECTED_APP_VERSION not in data["artifact_name"]:
            fail(f"{recipe.relative_to(REPO_ROOT)}: artifact_name missing {EXPECTED_APP_VERSION}")

        wf_rel = data["workflow"]
        check_contains(wf_rel, f"runs-on: {EXPECTED_MACOS_RUNNER}", f"pinned {EXPECTED_MACOS_RUNNER} runner")
        check_contains(wf_rel, EXPECTED_APP_VERSION, f"artifact version {EXPECTED_APP_VERSION}")
        wf_text = (REPO_ROOT / wf_rel).read_text(encoding="utf-8")
        if "macos-latest" in wf_text:
            fail(f"{wf_rel}: unpinned macos-latest violates ADR 0009")

    # 6. Main CI workflow pinned to macos-15 (ADR 0009)
    ci_text = (REPO_ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
    if "macos-latest" in ci_text:
        fail(".github/workflows/ci.yml: unpinned macos-latest violates ADR 0009")
    if EXPECTED_MACOS_RUNNER not in ci_text:
        fail(f".github/workflows/ci.yml: missing pinned {EXPECTED_MACOS_RUNNER} runner")

    print(
        f"macos versions & parity OK: app={EXPECTED_APP_VERSION} "
        f"(CFBundleVersion={EXPECTED_BUILD_NUMBER}), core={EXPECTED_CORE_VERSION}, "
        f"runner={EXPECTED_MACOS_RUNNER}, header parity=exact, 6 subplatform units aligned."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
