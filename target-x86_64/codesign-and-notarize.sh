#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# ADR 0009 two-stage macOS codesign and notarization script for Intel (x86_64).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_BUNDLE="${1:-${ROOT_DIR}/dist/x86_64/TotalDrop.app}"
DMG_PATH="${2:-}"

EXT_BUNDLE="${APP_BUNDLE}/Contents/PlugIns/FinderShareExtension.appex"

if [[ -z "${APPLE_DEVELOPER_ID_APPLICATION:-}" ]]; then
  echo "==> [x86_64] Applying ad-hoc signature (ADR 0009 account-free CI mode)"
  if [[ -d "${EXT_BUNDLE}" ]]; then
    codesign --force --sign - "${EXT_BUNDLE}"
  fi
  codesign --force --deep --sign - "${APP_BUNDLE}"
  codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"
  exit 0
fi

echo "==> [x86_64] Signing with Developer ID Application + Hardened Runtime"
if [[ -d "${EXT_BUNDLE}" ]]; then
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --entitlements "${ROOT_DIR}/target-arm64/entitlements.plist" \
    --sign "${APPLE_DEVELOPER_ID_APPLICATION}" \
    "${EXT_BUNDLE}"
fi
codesign \
  --force \
  --options runtime \
  --timestamp \
  --entitlements "${ROOT_DIR}/target-arm64/entitlements.plist" \
  --sign "${APPLE_DEVELOPER_ID_APPLICATION}" \
  "${APP_BUNDLE}"

codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"

if [[ -n "${DMG_PATH}" && -n "${APPLE_ASC_KEY_ID:-}" && -n "${APPLE_ASC_ISSUER_ID:-}" && -n "${APPLE_ASC_KEY_PATH:-}" ]]; then
  echo "==> [x86_64] Submitting ${DMG_PATH} to Apple Notary Service"
  xcrun notarytool submit "${DMG_PATH}" \
    --key "${APPLE_ASC_KEY_PATH}" \
    --key-id "${APPLE_ASC_KEY_ID}" \
    --issuer "${APPLE_ASC_ISSUER_ID}" \
    --wait
  xcrun stapler staple "${DMG_PATH}"
  spctl --assess --type open --context context:primary-signature --verbose "${DMG_PATH}"
fi
