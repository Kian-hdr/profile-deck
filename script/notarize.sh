#!/bin/bash
set -euo pipefail
# Run only after the maintainer explicitly approves upload of this exact package.
: "${PROFILE_DECK_APPROVED_UPLOAD:?Set to yes only after explicit upload approval.}"
test "$PROFILE_DECK_APPROVED_UPLOAD" = yes
: "${PROFILE_DECK_NOTARY_PROFILE:?Set the existing notarytool Keychain profile name.}"
DECK_ARTIFACT="${1:?Pass the exact reviewed DMG path.}"
xcrun notarytool submit "$DECK_ARTIFACT" --keychain-profile "$PROFILE_DECK_NOTARY_PROFILE" --wait
xcrun stapler staple "$DECK_ARTIFACT"
xcrun stapler validate "$DECK_ARTIFACT"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DECK_ARTIFACT"
shasum -a 256 "$DECK_ARTIFACT"
