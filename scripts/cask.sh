#!/bin/bash
# Writes Casks/cans.rb in the Homebrew tap (github.com/egno/homebrew-tap) for the latest git tag and the
# DMG built by `make release`. Publish the GitHub release first, then commit and push the tap.
#   make cask TAP=~/proj/homebrew-tap
set -euo pipefail
cd "$(dirname "$0")/.."

tap="${TAP:-../homebrew-tap}"
tap="${tap/#\~/$HOME}"  # make passes ~ unexpanded
version="${VERSION:-$(git describe --tags --abbrev=0 | sed 's/^v//')}"
dmg=dist/Cans-$version.dmg
[ -f "$dmg" ] || { echo "no $dmg: run make release VERSION=$version" >&2; exit 1; }
sha=$(shasum -a 256 "$dmg" | cut -d' ' -f1)

mkdir -p "$tap/Casks"
cat >"$tap/Casks/cans.rb" <<CASK
cask "cans" do
  version "$version"
  sha256 "$sha"

  url "https://github.com/egno/cans/releases/download/v#{version}/Cans-#{version}.dmg"
  name "Cans"
  desc "Unofficial menu bar app for Bose QuietComfort headphones"
  homepage "https://github.com/egno/cans"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "Cans.app"

  # Not notarized: clear the quarantine flag so macOS opens it.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Cans.app"]
  end

  uninstall quit: "io.github.egno.cans"

  zap trash: "~/Library/Preferences/io.github.egno.cans.plist"

  caveats <<~EOS
    Pair your headphones with the Mac in System Settings first. Cans asks for the Bluetooth
    permission on first start. Release builds are signed ad hoc, so after an upgrade macOS may ask again.
  EOS
end
CASK
echo "wrote $tap/Casks/cans.rb ($version, $sha)"
