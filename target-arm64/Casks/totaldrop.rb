# SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Homebrew Cask for TotalDrop on macOS (ADR 0009 step 5 & ADR 0015).
# Published to totaldrop-app/homebrew-tap once Developer ID notarization is active.

cask "totaldrop" do
  arch arm: "arm64", intel: "x86_64"

  version "0.3.0-beta.6"
  sha256 arm:   "REPLACE_WITH_CI_ARM64_DMG_SHA256",
         intel: "REPLACE_WITH_CI_X86_64_DMG_SHA256"

  url "https://github.com/totaldrop-app/totaldrop-macos/releases/download/macos-dmg-#{arch}-v#{version}/TotalDrop-#{version}-#{arch}.dmg",
      verified: "github.com/totaldrop-app/totaldrop-macos/"
  name "TotalDrop"
  desc "Send files straight to another device, end-to-end encrypted"
  homepage "https://totaldrop.app"

  depends_on macos: ">= :sequoia"

  app "TotalDrop.app"

  zap trash: [
    "~/Library/Application Scripts/app.totaldrop.mac",
    "~/Library/Containers/app.totaldrop.mac",
    "~/Library/Group Containers/group.app.totaldrop.mac",
    "~/Library/Preferences/app.totaldrop.mac.plist",
  ]
end
