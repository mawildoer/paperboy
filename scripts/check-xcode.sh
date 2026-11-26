#!/bin/sh
# Fail before building if the selected SDK cannot meet Apple's upload requirement.
set -eu
xcodebuild -version
sdk_version="$(xcrun --sdk iphoneos --show-sdk-version)"
printf 'Selected iOS SDK: %s\n' "$sdk_version"
sdk_major="${sdk_version%%.*}"
case "$sdk_major" in
  ''|*[!0-9]*) echo 'Could not determine the iOS SDK major version.' >&2; exit 1 ;;
esac
if [ "$sdk_major" -lt 27 ]; then
  echo 'Paperboy distribution requires the iOS 27 SDK or newer. Select Xcode 27 or newer.' >&2
  exit 1
fi
