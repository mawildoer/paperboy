#!/bin/bash
# Archive with automatic signing, then upload for TestFlight (not App Review).
set -euo pipefail

: "${ASC_KEY_ID:?Set ASC_KEY_ID to the App Store Connect team key ID}"
: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID to the App Store Connect issuer ID}"
: "${ASC_PRIVATE_KEY:?Set ASC_PRIVATE_KEY to the contents of the downloaded .p8 file}"
: "${BUILD_NUMBER:?Set BUILD_NUMBER to a new CFBundleVersion}"

ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
sh "$ROOT/scripts/check-xcode.sh"
TEAM_ID="${TEAM_ID:-PTVJRD6TRB}"
OUT="${TESTFLIGHT_OUTPUT:-$ROOT/.build/testflight/$BUILD_NUMBER}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
if [[ -e "$OUT/Paperboy.xcarchive" ]]; then
  echo 'Archive already exists; choose a new BUILD_NUMBER or TESTFLIGHT_OUTPUT.' >&2
  exit 1
fi

umask 077
KEY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/paperboy-asc.XXXXXX")"
trap 'rm -rf "$KEY_DIR"' EXIT
printf '%s\n' "$ASC_PRIVATE_KEY" > "$KEY_DIR/AuthKey.p8"
unset ASC_PRIVATE_KEY
openssl pkey -in "$KEY_DIR/AuthKey.p8" -noout >/dev/null
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY_DIR/AuthKey.p8"
      -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

cd "$ROOT/Paperboy"
xcodegen generate
xcodebuild -project Paperboy.xcodeproj -scheme Paperboy -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$OUT/Paperboy.xcarchive" \
  DEVELOPMENT_TEAM="$TEAM_ID" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  "${AUTH[@]}" archive

python3 - "$OUT/Paperboy.xcarchive/Products/Applications/Paperboy.app" <<'PY'
from pathlib import Path
import plistlib
import re
import sys
app = Path(sys.argv[1])
for bundle in [app, *sorted((app / "PlugIns").glob("*.appex"))]:
    with (bundle / "Info.plist").open("rb") as info:
        sdk = plistlib.load(info).get("DTSDKName", "")
    version = re.fullmatch(r"iphoneos(\d+)(?:\.\d+)*", sdk)
    if not version or int(version[1]) < 27:
        raise SystemExit(f"Refusing upload: {bundle.name} was built with unsupported SDK {sdk!r}")
    print(f"Validated archived SDK: {bundle.name} {sdk}")
PY

python3 - "$OUT/ExportOptions.plist" "$TEAM_ID" <<'PY'
import plistlib
import sys
with open(sys.argv[1], "wb") as output:
    plistlib.dump({
        "method": "app-store-connect",
        "destination": "upload",
        "signingStyle": "automatic",
        "teamID": sys.argv[2],
        "manageAppVersionAndBuildNumber": False,
        "uploadSymbols": True,
    }, output)
PY

xcodebuild -exportArchive -archivePath "$OUT/Paperboy.xcarchive" \
  -exportPath "$OUT/export" -exportOptionsPlist "$OUT/ExportOptions.plist" "${AUTH[@]}"
printf 'Uploaded Paperboy build %s. Apple must finish processing before it is available in TestFlight.\n' "$BUILD_NUMBER"
swift "$ROOT/scripts/check-testflight.swift" "$KEY_DIR/AuthKey.p8" "$ASC_KEY_ID" "$ASC_ISSUER_ID" "$BUILD_NUMBER"
