#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PROFILE_DECK_SIGNING_IDENTITY:?Set a local Developer ID Application identity.}"
DECK_VERSION=$(sed -n 's/^[[:space:]]*MARKETING_VERSION: //p' project.yml | head -1)
DECK_BUILD=$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION: //p' project.yml | head -1)
test -n "$DECK_VERSION" && test -n "$DECK_BUILD"
DECK_CACHE="${PROFILE_DECK_PACKAGE_CACHE:-$HOME/Library/Caches/ProfileDeck/Packaging}"
mkdir -p "$DECK_CACHE" dist
DECK_STAGE=$(mktemp -d "$DECK_CACHE/package.XXXXXX")
# Only this invocation's disposable, generated staging directory is removed.
trap 'rm -rf "$DECK_STAGE"' EXIT
xcodegen generate
xcodebuild -project ProfileDeck.xcodeproj -scheme ProfileDeck -configuration Release \
  -archivePath "$DECK_STAGE/ProfileDeck.xcarchive" -derivedDataPath "$DECK_CACHE/DerivedData" \
  CODE_SIGN_IDENTITY="$PROFILE_DECK_SIGNING_IDENTITY" ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS='--timestamp' archive > "$DECK_CACHE/archive.log" 2>&1
DECK_APP="$DECK_STAGE/ProfileDeck.xcarchive/Products/Applications/Profile Deck.app"
codesign --verify --deep --strict "$DECK_APP"
mkdir -p "$DECK_STAGE/disk"
ditto --norsrc --noextattr "$DECK_APP" "$DECK_STAGE/disk/Profile Deck.app"
ln -s /Applications "$DECK_STAGE/disk/Applications"
cp README.md LICENSE THIRD_PARTY_NOTICES "$DECK_STAGE/disk/"
ditto THIRD_PARTY_LICENSES "$DECK_STAGE/disk/THIRD_PARTY_LICENSES"
DECK_DMG="dist/Profile-Deck-${DECK_VERSION}-arm64.dmg"
if test -e "$DECK_DMG"; then echo 'Existing package preserved. Move it aside before regenerating.' >&2; exit 2; fi
hdiutil create -volname "Profile Deck $DECK_VERSION" -srcfolder "$DECK_STAGE/disk" -format UDZO -ov "$DECK_DMG"
codesign --sign "$PROFILE_DECK_SIGNING_IDENTITY" --timestamp "$DECK_DMG"
./script/source_archive.sh
shasum -a 256 "$DECK_DMG" "dist/Profile-Deck-${DECK_VERSION}-source.zip" > dist/SHA256SUMS
codesign --display --verbose=4 "$DECK_APP" 2> dist/signature.txt
printf 'Local package prepared. Not uploaded, notarized, stapled or published.\n'
