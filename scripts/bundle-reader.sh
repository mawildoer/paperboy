#!/bin/sh
# Rebuild Safari's single required preprocessing file from the pinned library and local wrappers.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cat "$ROOT/PaperboyCore/Sources/PaperboyCore/Resources/Readability.js" \
    "$ROOT/PaperboyCore/Sources/PaperboyCore/Resources/ReaderMode.js" \
    "$ROOT/scripts/SharePage.wrapper.js" > "$ROOT/Paperboy/ShareExtension/SharePage.js"
