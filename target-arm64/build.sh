#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Apple Silicon (M1-M4, aarch64-apple-darwin) build unit for TotalDrop on macOS.
# Produces TotalDrop.app linked against libtotaldrop_macos_ffi.a with Kose AppIcon.icns,
# 35-language Localizable.xcstrings, AASA, and FinderShareExtension.appex.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RUST_TARGET="aarch64-apple-darwin"
SWIFT_ARCH="arm64"
VERSION="${TOTALDROP_VERSION:-0.3.0-beta.6}"
BUILD_NUMBER="${TOTALDROP_BUILD_NUMBER:-6}"
OUT_DIR="${ROOT_DIR}/dist/arm64"
APP_BUNDLE="${OUT_DIR}/TotalDrop.app"

export MACOSX_DEPLOYMENT_TARGET="15.0"

echo "==> [arm64] Building Rust C ABI FFI staticlib (${RUST_TARGET})"
rustup target add "${RUST_TARGET}"
cargo build \
  --manifest-path "${ROOT_DIR}/Cargo.toml" \
  --package totaldrop-macos-ffi \
  --target "${RUST_TARGET}" \
  --release \
  --locked

echo "==> [arm64] Building Swift 6 macOS UI and Finder Share Extension (${SWIFT_ARCH})"
swift build \
  --package-path "${ROOT_DIR}/ui-swiftui-macos" \
  --product TotalDropMac \
  --arch "${SWIFT_ARCH}" \
  --configuration release \
  -Xlinker "-L${ROOT_DIR}/target/${RUST_TARGET}/release" \
  -Xlinker "-ltotaldrop_macos_ffi"

swift build \
  --package-path "${ROOT_DIR}/ui-swiftui-macos" \
  --product FinderShareExtension \
  --arch "${SWIFT_ARCH}" \
  --configuration release

BIN_DIR="$(swift build \
  --package-path "${ROOT_DIR}/ui-swiftui-macos" \
  --arch "${SWIFT_ARCH}" \
  --configuration release \
  --show-bin-path)"

echo "==> [arm64] Assembling TotalDrop.app bundle"
rm -rf "${APP_BUNDLE}"
mkdir -p \
  "${APP_BUNDLE}/Contents/MacOS" \
  "${APP_BUNDLE}/Contents/PlugIns/FinderShareExtension.appex/Contents/MacOS" \
  "${APP_BUNDLE}/Contents/Resources"

cp "${BIN_DIR}/TotalDropMac" "${APP_BUNDLE}/Contents/MacOS/TotalDropMac"
chmod 755 "${APP_BUNDLE}/Contents/MacOS/TotalDropMac"

if [[ -f "${BIN_DIR}/libFinderShareExtension.dylib" ]]; then
  cp "${BIN_DIR}/libFinderShareExtension.dylib" \
     "${APP_BUNDLE}/Contents/PlugIns/FinderShareExtension.appex/Contents/MacOS/libFinderShareExtension.dylib"
  chmod 755 "${APP_BUNDLE}/Contents/PlugIns/FinderShareExtension.appex/Contents/MacOS/libFinderShareExtension.dylib"
fi

sed \
  -e "s/@VERSION@/${VERSION}/g" \
  -e "s/@BUILD_NUMBER@/${BUILD_NUMBER}/g" \
  "${SCRIPT_DIR}/Info.plist" > "${APP_BUNDLE}/Contents/Info.plist"

sed \
  -e "s/@VERSION@/${VERSION}/g" \
  -e "s/@BUILD_NUMBER@/${BUILD_NUMBER}/g" \
  "${SCRIPT_DIR}/FinderShareExtension-Info.plist" \
  > "${APP_BUNDLE}/Contents/PlugIns/FinderShareExtension.appex/Contents/Info.plist"

cp "${ROOT_DIR}/ui-swiftui-macos/Resources/AppIcon.icns" \
   "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
cp "${ROOT_DIR}/ui-swiftui-macos/Resources/Localizable.xcstrings" \
   "${APP_BUNDLE}/Contents/Resources/Localizable.xcstrings"
cp "${ROOT_DIR}/ui-swiftui-macos/apple-app-site-association" \
   "${APP_BUNDLE}/Contents/Resources/apple-app-site-association"

echo "APPL????" > "${APP_BUNDLE}/Contents/PkgInfo"
echo "==> [arm64] Bundle staged at ${APP_BUNDLE}"
