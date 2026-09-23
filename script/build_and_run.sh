#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
MODE="${1:-run}"
case "$MODE" in run|build|--build|--demo|--demo-scale|--debug|--logs|--telemetry|--verify) ;; *) echo 'Usage: build_and_run.sh [--build|--demo|--demo-scale|--debug|--logs|--telemetry|--verify]'; exit 2 ;; esac
if [[ "$MODE" != build && "$MODE" != --build ]] && /usr/bin/pgrep -x 'Profile Deck' >/dev/null; then
  echo 'Profile Deck is running. Quit it normally before launching a development build.' >&2
  exit 1
fi
xcodegen generate
DERIVED_DATA="${PROFILE_DECK_DERIVED_DATA:-$HOME/Library/Caches/ProfileDeck/DerivedData}"
xcodebuild -project ProfileDeck.xcodeproj -scheme ProfileDeck -configuration Debug -derivedDataPath "$DERIVED_DATA" build > build-output.log 2>&1 || { tail -80 build-output.log; exit 1; }
APP="$DERIVED_DATA/Build/Products/Debug/Profile Deck.app"
case "$MODE" in
  build|--build) exit 0 ;;
  --demo) open -n "$APP" --args --demo ;;
  --demo-scale) open -n "$APP" --args --demo --demo-scale ;;
  --debug) lldb "$APP/Contents/MacOS/Profile Deck" ;;
  --logs|--telemetry) open -n "$APP"; /usr/bin/log stream --info --predicate 'process == "Profile Deck"' ;;
  --verify) open -n "$APP"; sleep 1; pgrep -x 'Profile Deck' >/dev/null ;;
  run) open -n "$APP" ;;
esac
