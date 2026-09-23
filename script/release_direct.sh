#!/bin/bash
# Build and notarize a local direct-download release. This script never publishes.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${PROFILE_DECK_SIGNING_IDENTITY:?Set an installed Developer ID Application identity}"
: "${PROFILE_DECK_NOTARY_PROFILE:?Name an existing notarytool Keychain profile}"
: "${PROFILE_DECK_RELEASE_OUTPUT_DIR:?Choose a new output directory outside the repository}"
test ! -e "$PROFILE_DECK_RELEASE_OUTPUT_DIR" || {
  echo 'Release output already exists; choose a new directory.' >&2
  exit 2
}
test -z "$(git status --porcelain)" || {
  echo 'Release source must be a clean, identified commit.' >&2
  exit 2
}

source_commit=$(git rev-parse HEAD)
version=$(sed -n 's/^[[:space:]]*MARKETING_VERSION: //p' project.yml | head -1)
build=$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION: //p' project.yml | head -1)
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[0-9]+$ ]] || {
  echo 'Release version/build are invalid.' >&2
  exit 2
}

out=$PROFILE_DECK_RELEASE_OUTPUT_DIR
work="$out/work"
mkdir -p "$work" "$out"
xcodegen generate
xcodebuild -project ProfileDeck.xcodeproj -scheme ProfileDeck \
  -configuration Release -archivePath "$work/ProfileDeck.xcarchive" \
  -derivedDataPath "$work/DerivedData" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$PROFILE_DECK_SIGNING_IDENTITY" \
  ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS=--timestamp \
  archive > "$out/archive.log" 2>&1

app="$out/Profile Deck.app"
ditto --norsrc "$work/ProfileDeck.xcarchive/Products/Applications/Profile Deck.app" "$app"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" = "$version"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")" = "$build"
codesign --verify --deep --strict --verbose=2 "$app" > "$out/app-signature.log" 2>&1

ditto -c -k --keepParent "$app" "$work/app-notary.zip"
xcrun notarytool submit "$work/app-notary.zip" \
  --keychain-profile "$PROFILE_DECK_NOTARY_PROFILE" --wait --output-format json \
  > "$out/app-notary.json"
app_id=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["status"]=="Accepted", d; print(d["id"])' "$out/app-notary.json")
xcrun notarytool log "$app_id" --keychain-profile "$PROFILE_DECK_NOTARY_PROFILE" "$out/app-notary-log.json" >/dev/null
xcrun stapler staple "$app" >/dev/null
xcrun stapler validate "$app" >/dev/null
codesign --verify --deep --strict "$app"
spctl --assess --type execute --verbose=4 "$app"

zip="$out/Profile-Deck-$version-arm64.zip"
ditto -c -k --keepParent "$app" "$zip"
mkdir -p "$work/dmg-root"
ditto --norsrc "$app" "$work/dmg-root/Profile Deck.app"
ln -s /Applications "$work/dmg-root/Applications"
cp LICENSE THIRD_PARTY_NOTICES "$work/dmg-root/"
dmg="$out/Profile-Deck-$version-arm64.dmg"
hdiutil create -volname "Profile Deck $version" -srcfolder "$work/dmg-root" -format UDZO "$dmg" > "$out/dmg-create.log" 2>&1
codesign --timestamp --sign "$PROFILE_DECK_SIGNING_IDENTITY" "$dmg"
codesign --verify --strict "$dmg"
xcrun notarytool submit "$dmg" \
  --keychain-profile "$PROFILE_DECK_NOTARY_PROFILE" --wait --output-format json \
  > "$out/dmg-notary.json"
dmg_id=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["status"]=="Accepted", d; print(d["id"])' "$out/dmg-notary.json")
xcrun notarytool log "$dmg_id" --keychain-profile "$PROFILE_DECK_NOTARY_PROFILE" "$out/dmg-notary-log.json" >/dev/null
xcrun stapler staple "$dmg" >/dev/null
xcrun stapler validate "$dmg" >/dev/null
hdiutil verify "$dmg" > "$out/dmg-verify.log" 2>&1
spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg"

source_zip="$out/Profile-Deck-$version-source.zip"
git archive --format=zip --prefix="Profile-Deck-$version/" --output="$source_zip" "$source_commit"
(cd "$out" && shasum -a 256 "$(basename "$dmg")" "$(basename "$zip")" "$(basename "$source_zip")" > SHA256SUMS)
printf '%s\n' "$source_commit" > "$out/SOURCE_COMMIT"
test "$(git rev-parse HEAD)" = "$source_commit"
test -z "$(git status --porcelain)"
echo "Signed, notarized local release prepared: $out"
echo 'Install and launch the final DMG, then publish and re-download exact bytes.'
