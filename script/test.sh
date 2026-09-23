#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
DERIVED_DATA="${PROFILE_DECK_DERIVED_DATA:-$HOME/Library/Caches/ProfileDeck/DerivedData}"
xcodebuild -project ProfileDeck.xcodeproj -scheme ProfileDeck -configuration Debug -derivedDataPath "$DERIVED_DATA" -destination 'platform=macOS,arch=arm64' test "$@"
