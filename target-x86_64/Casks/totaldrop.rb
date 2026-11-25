# SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Intel Mac (x86_64-apple-darwin) Homebrew Cask recipe for TotalDrop on macOS.

cask "totaldrop" do
  version "0.3.0-beta.6"
  sha256 "REPLACE_WITH_CI_X86_64_DMG_SHA256"

  url "https://github.com/totaldrop-app/totaldrop-macos/releases/download/macos-dmg-x86_64-v#{version}/TotalDrop-#{version}-x86_64.dmg",
      verified: "github.com/totaldrop-app/totaldrop-macos/"
  name "TotalDrop"
  desc "Send files straight to another device, end-to-end encrypted (Intel Mac)"
  homepage "https://totaldrop.app"

  depends_on macos: ">= :sequoia"
  depends_on arch: :x86_64

  app "TotalDrop.app"

  zap trash: [
    "~/Library/Application Scripts/app.totaldrop.mac",
    "~/Library/Containers/app.totaldrop.mac",
    "~/Library/Group Containers/group.app.totaldrop.mac",
    "~/Library/Preferences/app.totaldrop.mac.plist",
  ]
end
