#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift test --package-path PaperboyCore
swift build --package-path paperboy-cli
(cd Paperboy && xcodegen generate)
swift tests/share-activation.swift
xcodebuild -project Paperboy/Paperboy.xcodeproj -scheme Paperboy -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath .build/ios CODE_SIGNING_ALLOWED=NO build
