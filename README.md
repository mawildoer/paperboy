# Paperboy

<img src="Paperboy/Sources/Assets.xcassets/AppIcon.appiconset/paperboy-v2-1024.png" alt="Paperboy icon" width="128" height="128">

An iPhone companion for reading articles on a Xteink X3 instead of a phone. Paperboy caches text as EPUB and delivers it to the reader over Bluetooth, ready to read offline. It includes a Safari share extension, local Mozilla Readability extraction, signed-in Substack and Medium fetching, and compact black-and-white article images with extra detail for charts. NYT support is experimental and is not verified for public release.

Requires the matching [Paperboy CrossPoint firmware](https://github.com/mawildoer/crosspoint-reader). This is an independent project, not an official Xteink, Substack, Medium, NYT, or CrossPoint product. Background delivery depends on iOS scheduling and reader availability; it is not guaranteed on a fixed interval.

## Source layout

- `Paperboy/`: SwiftUI iPhone app, share extension, new icon, and XcodeGen project specification.
- `PaperboyCore/`: Swift package containing EPUB generation, article storage, parsers, sync protocol, and Core Bluetooth transport.
- `paperboy-cli/`: Mac test tool for delivering EPUB/HTML files over Bluetooth.
- `docs/`: Bluetooth protocol, privacy draft, and App Store preparation.

## Build

Use full Xcode with the iOS SDK, Swift 6, and XcodeGen (`brew install xcodegen`). CI runs the full source and OCR tests on macOS 26, then builds the iOS app on `xcode-27` with Xcode 27.2. TestFlight uploads require iOS SDK 27 or newer, checked both before building and in the archived app/extension metadata. Earlier Xcode versions are not guaranteed.

```sh
./scripts/check.sh
cd Paperboy
xcodegen generate
open Paperboy.xcodeproj
```

Choose your signing team in Xcode before installing on a phone. The existing bundle identifiers and app group belong to this project; change all three together if building a differently identified app. Source and icon updates do not overwrite the original development checkout or the app already on a phone.

To run just the shared tests:

```sh
swift test --package-path PaperboyCore
```

The Mac tool supports `scan`, `list`, `demo`, `push`, and `sync`; see `paperboy-cli --help` after building. A simulation is available with `paperboy-cli demo --fake`.

## Use

Allow Bluetooth, open Library on the reader, and pair from Paperboy. Sign into Substack or Medium in the app, or share a page from Safari to Paperboy. Medium monitors your signed-in Following page; no separate subscriptions are configured. Email sign-in links can be pasted into the Medium login sheet. Find articles with the search bar (title, author, and source, including small typos). Load articles onto the reader; lock one to keep it after completion. Bump a loaded article to the top of the reader’s Touched view without changing its reading position. The reader offers Touched, Added, and Published views, all newest first. Unfinished loaded articles retain their reading position on the reader.

Settings also offers Bluetooth firmware updates for the matching reader firmware (USB bootstrap required once). Updates use the project's GitHub release, verify its SHA-256, stage on the reader, and confirm the new version after reboot. Keep the reader in Library and connected to USB or charged above 30%.

See [extraction and image limits](docs/extraction-and-images.md). PDFs can be shared from Safari or Files, or opened in Paperboy. Native PDF text is extracted locally; scans use on-device OCR, and monochrome page images retain charts. Current limits: one PDF, 20 MB, 20 pages, and 512 KiB of processed images. Cloud/LLM extraction remains disabled.

## Distribution status

Development source, not an App Store release. See [the release checklist and CI setup](docs/app-store-release.md). Normal CI runs tests and an unsigned iOS build. The **Publish TestFlight** workflow archives and uploads with automatic signing on a `v*` tag or a manual run on `main`, once the Apple API secrets are configured. App Review and public App Store release remain separate steps.

No account sessions, signing certificates, device backups, or personal article libraries are included.
