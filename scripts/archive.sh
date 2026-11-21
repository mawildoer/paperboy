#!/bin/sh
# Creates a signed archive; does not upload or submit it.
set -eu
: "TEAM_ID:?Set TEAM_ID to your paid Apple Developer team ID}"
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
ARCHIVE_PATH="${ARCHIVE_PATH:-$ROOT/.build/archives/Paperboy.xcarchive}"
cd "$ROOT/Paperboy"
xcodegen generate
xcodebuild -project Paperboy.xcodeproj -scheme Paperboy -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE_PATH" \
  DEVELOPMENT_TEAM="$TEAM_ID" -allowProvisioningUpdates archive
printf 'Archive ready: %s\nValidate and distribute from Xcode Organizer.\n' "$ARCHIVE_PATH"
