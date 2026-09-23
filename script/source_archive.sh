#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(git show HEAD:project.yml | sed -n 's/.*MARKETING_VERSION: //p' | head -1)
test -n "$VERSION"
git diff --exit-code HEAD -- ProfileDeck ProfileDeckTests project.yml script README.md PRIVACY.md LICENSE THIRD_PARTY_NOTICES THIRD_PARTY_LICENSES docs
mkdir -p dist
ARCHIVE="dist/Profile-Deck-${VERSION}-source.zip"
test ! -e "$ARCHIVE" || { echo "Existing source archive preserved" >&2; exit 2; }
# Archive only the reviewed commit, never untracked files or local evidence.
git archive --format=zip --prefix="Profile-Deck-${VERSION}/" --output="$ARCHIVE" HEAD
shasum -a 256 "$ARCHIVE"
