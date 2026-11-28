# Paperboy

<img src="Paperboy/Sources/Assets.xcassets/AppIcon.appiconset/paperboy-v2-1024.png" alt="Paperboy icon" width="128" height="128">

An iPhone companion for reading articles on a Xteink X3 instead of a phone. Paperboy caches text as EPUB and delivers it to the reader over Bluetooth, ready to read offline. It includes a Safari share extension, local Mozilla Readability extraction, signed-in Substack, Medium and Economist fetching, and compact black-and-white article images with extra detail for charts. NYT support is experimental and is not verified for public release.

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

Allow Bluetooth, open Library on the reader, and pair from Paperboy. Sign in to your publishers under **Sources**. Sharing a Substack, Medium, New York Times or Economist story opens the link in Paperboy’s signed-in browser and queues the resulting article for the reader. Re-sharing refreshes the phone copy, even if the sharing app supplied a preview. In Apple News, open a story and choose **Share → Paperboy**. Paperboy imports the linked publisher edition when you have access and queues it for the reader. Medium monitors your signed-in Following page; no separate subscriptions are configured. Email sign-in links can be pasted into the Medium login sheet. Find articles with the search bar (title, author, and source, including small typos). Load articles onto the reader; lock one to keep it after completion. Bump a loaded article to the top of the reader’s Touched view without changing its reading position. The reader offers Touched, Added, and Published views, all newest first. Unfinished loaded articles retain their reading position on the reader.

For **The Economist**, open **Sources → The Economist → Sign in**, log in on the website and tap **Use this session**. Paperboy checks the front page on refresh and during scheduled fetches, saving up to ten new stories per fetch by default. Change the limit in **Settings → The Economist**. Use **Load** to send a fetched story to your reader. To send one directly, open a readable story in Safari or The Economist app and choose **Share → Paperboy**.

Use **Update** beside the firmware version on the main page for a manual Bluetooth update. **Settings → Reader firmware → Automatically update** is enabled by default. After article sync, Paperboy checks for a newer stable release, caches the verified download, and stages it on the reader. Protocol 3 readers retain partial firmware transfers across sync windows and restarts; shorter windows send up to 256 KiB, while a longer window validates the complete file and installs it in the inactive slot. If a download is interrupted, automatic updates retry at a later sync. A newer image already verified on the phone can install over Bluetooth while the phone is offline. iOS chooses when background work runs. Keep the reader in Library and powered or charged above 30%. The app confirms the new version after reboot. Older Bluetooth firmware needs one complete update to acquire resume support; the original USB bootstrap is still required only on devices that lack Bluetooth updates entirely.

See [extraction and image limits](docs/extraction-and-images.md). PDFs can be shared from Safari or Files, or opened in Paperboy. Native PDF text is extracted locally; scans use on-device OCR, and monochrome page images retain charts. Current limits: one PDF, 20 MB, 20 pages, and 512 KiB of processed images. Cloud/LLM extraction remains disabled.

## Distribution status

Development source, not an App Store release. See [the release checklist and CI setup](docs/app-store-release.md). Normal CI runs tests and an unsigned iOS build. The **Publish TestFlight** workflow archives and uploads with automatic signing on a `v*` tag or a manual run on `main`, once the Apple API secrets are configured. App Review and public App Store release remain separate steps.

No account sessions, signing certificates, device backups, or personal article libraries are included.
