#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Packages TotalDrop.app (Intel x86_64) into a compressed UDZO .dmg
# with an Applications drop-link and emits SHA256SUMS.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSION="${TOTALDROP_VERSION:-0.3.0-beta.6}"
OUT_DIR="${ROOT_DIR}/dist/x86_64"
APP_BUNDLE="${OUT_DIR}/TotalDrop.app"
STAGING_DIR="${OUT_DIR}/dmg-staging"
DMG_NAME="TotalDrop-${VERSION}-x86_64.dmg"
DMG_PATH="${OUT_DIR}/${DMG_NAME}"

rm -rf "${STAGING_DIR}" "${DMG_PATH}"
mkdir -p "${STAGING_DIR}"
cp -R "${APP_BUNDLE}" "${STAGING_DIR}/TotalDrop.app"
ln -s /Applications "${STAGING_DIR}/Applications"

hdiutil create \
  -volname "TotalDrop" \
  -srcfolder "${STAGING_DIR}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

rm -rf "${STAGING_DIR}"

(
  cd "${OUT_DIR}"
  shasum -a 256 "${DMG_NAME}" > SHA256SUMS
)
echo "==> [x86_64] Created ${DMG_PATH}"
