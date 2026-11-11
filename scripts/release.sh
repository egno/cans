#!/bin/zsh
# Package build/Cans.app as dist/Cans-<version>.zip and .dmg.
# Usage: scripts/release.sh <version>
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>}"
./scripts/bundle.sh "$VERSION"

mkdir -p dist
ZIP="dist/Cans-$VERSION.zip"
DMG="dist/Cans-$VERSION.dmg"
rm -f "$ZIP" "$DMG"

ditto -c -k --keepParent build/Cans.app "$ZIP"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R build/Cans.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Cans $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

shasum -a 256 "$ZIP" "$DMG"
