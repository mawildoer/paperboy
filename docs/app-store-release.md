# App Store preparation

Status: Paperboy 0.1 build 101.1 was uploaded and validated for internal TestFlight testing on 2026-11-25. It has not been submitted to App Review or released on the public App Store.

Initial local verification on 2026-11-20: 126 shared tests passed; the Mac sync tool built; the unsigned Release iOS app and share extension built; both privacy manifests were present in the built bundles. Distribution validation was completed later, as recorded below.

## Prepared

- Separate iOS app, share extension, shared Swift package, and Mac test-tool source.
- XcodeGen project, 1024px opaque icon, usage descriptions, version/build settings, and App Group entitlements.
- Privacy manifests for the app and share extension. The app declares local UserDefaults use (`CA92.1`). Neither includes developer tracking or developer-collected data declarations; these must be re-audited before submission, including embedded publisher web pages.
- CI runs package tests, builds the Mac tool, and builds the Release iOS app/extension without signing.
- `TEAM_ID=YOUR_PAID_TEAM ./scripts/archive.sh` creates a signed archive. This script does not upload or submit anything.

## TestFlight from GitHub Actions

The **Publish TestFlight** workflow (`.github/workflows/testflight.yml`) runs on app tags beginning with `v` or manually on `main`. It runs the extraction, Swift, and share-registration checks, archives the app and extension with Xcode automatic signing, and uploads to App Store Connect. It then checks Apple's API for up to 20 minutes, requiring processing state `VALID` and an internal TestFlight state of `READY_FOR_BETA_TESTING` or `IN_BETA_TESTING`. It does not submit to App Review or publish to the public App Store. TestFlight tester/group configuration remains separate.

In this repository's **Settings → Secrets and variables → Actions**, create these repository secrets:

| Secret | Value |
| --- | --- |
| `ASC_PRIVATE_KEY` | Complete PEM contents of the downloaded `AuthKey_….p8` file, including the BEGIN/END lines. |
| `ASC_KEY_ID` | The team API key's Key ID. |
| `ASC_ISSUER_ID` | The App Store Connect Issuer ID. |

Create a **team** API key under App Store Connect **Users and Access → Integrations → App Store Connect API**. Its role must permit provisioning and cloud-managed distribution signing; an Admin team key has the needed access. Xcode uses it for both the app and share extension. The app record uses `app.paperboy.readerc67aad`, with team `PTVJRD6TRB` and shared app group `group.app.paperboy.readerc67aad`.

GitHub cannot reveal stored secret values. The workflow writes the key to a private temporary file, removes it on exit, uses a temporary signing keychain, and uploads only debug symbols as a workflow artifact. Do not put keys, certificates, signing identities, or profiles in repository files or issue comments. Revoke a compromised API key in App Store Connect and replace the three secrets.

Each run receives a build number of `100 + workflow run number`, followed by the run attempt (for example, `101.1`). A retry has a new build number. The app and extension receive the same value. After adding the secrets, open **Actions → Publish TestFlight → Run workflow**, choose `main`, and run it. Successful upload does not mean Apple has finished processing the build.

iOS build, upload, and status jobs use GitHub's `xcode-27` runner and select `/Applications/Xcode_27.2.app/Contents/Developer`. `scripts/check-xcode.sh` requires iOS SDK 27 or newer before a distribution build; the upload script independently validates `DTSDKName` in the archived app and share extension. This addresses Apple's ITMS-90725 warning ahead of its April 2027 deadline. [GitHub runner software](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md).

The reusable source-check workflow runs all extraction, package, scanned-PDF OCR, sharing, and Mac-tool checks on `macos-26`. Both normal CI and TestFlight publication require this job to pass before the Xcode 27.2 build. The hosted macOS 27 runtime currently fails Vision's accurate OCR with `TextRecognition.CRImageReaderError` code 9; a fast-engine retry misread the test chart, so that workaround was removed. No OCR test is skipped or relaxed. This runtime pin does not lower the distribution SDK; the archive guards still require SDK 27+. Revisit the runtime pin when the hosted image's Vision backend works.

For an equivalent local upload, set the three `ASC_*` variables and a new `BUILD_NUMBER`, select full Xcode using `DEVELOPER_DIR`, then run `bash scripts/testflight.sh`. Optional `TEAM_ID` and `TESTFLIGHT_OUTPUT` override the team and output directory. The script refuses to replace an existing archive and stops if archiving or uploading fails.

To recheck a build that was already uploaded, manually run **Validate TestFlight** on `main` and enter its build number. This workflow only reads Apple status; it does not create another build or send invitations. It uses the same three secrets, signs short-lived API tokens locally on the runner, prints processing/beta states and the app link, and removes its private-key file on exit. If Apple processing takes longer than 20 minutes, rerun this status check rather than uploading the same build again.

References: [Apple's cloud-signing automation](https://developer.apple.com/videos/play/wwdc2021/10204/), [App Store Connect API setup](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/), and [upload processing](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/).

## Remaining gates

1. **Distribution account.** The paid team and Admin API key authenticated successfully in CI on 2026-11-25. Xcode archived, cloud-signed, and uploaded build 101.1. Account agreements and signing access remain the account holder's responsibility.
2. **App identity and capabilities.** The app record is `6838137167` for `app.paperboy.readerc67aad`. The `.share` extension and shared app group `group.app.paperboy.readerc67aad` were included in the successful signed archive. If changing identities, update code constants, the project spec, entitlement files, and Apple registrations together.
3. **Content access permissions.** Substack and NYT use undocumented/private endpoints and signed-in web views. Verify that public distribution is permitted under each service's terms and obtain authorization if necessary. A paid reader subscription alone does not establish distribution permission. Keep NYT out of launch claims until login and fetching are verified. Consider a first release centered on user-initiated sharing of permitted pages if direct integrations cannot be cleared.
4. **Privacy.** Review [the draft policy](privacy-draft.md), publish a stable privacy-policy URL, link it in the app, and fill App Store Connect privacy answers from a final audit. Recheck manifests against the archive privacy report. Audit logs, cookies, the share extension, publisher pages, retention, device transfer, and removal of local data. Establish user-facing controls/documentation for clearing cached articles and logs; current sign-out should not be assumed to remove all downloaded content.
5. **Product validation.** Test fresh installs, denied permissions, expired sign-ins, custom-domain subscriptions, missing content access, Bluetooth reconnect/restoration, reader sleep, background fetching, large transfers, interrupted sync, and the share extension. Confirm unfinished articles resume and are not deleted during synchronization. Do not promise continuous or scheduled background availability.
6. **Reviewer access.** Prepare sample content you have rights to share, clear setup steps, and an explanation of the hardware dependency. Arrange a reviewable path or demo approach acceptable to App Review; a physical X3 and private subscriptions cannot be assumed available to reviewers.
7. **Listing.** Supply accurate screenshots, description, support URL/contact, privacy URL, age rating, content-rights answers, encryption declarations, territories/pricing, and reviewer notes. Do not assume the current encryption flag is a completed export-compliance assessment.
8. **Release.** CI archive/upload and Apple processing validation passed for build 101.1. Configure the internal tester group and test on a physical phone, then complete the public App Store preparation and App Review separately. No distribution key, password, certificate, or provisioning profile belongs in Git.

## Apple references

- [Program enrollment](https://developer.apple.com/help/account/membership/program-enrollment/)
- [App Store Connect workflow](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-workflow)
- [Submitting apps](https://developer.apple.com/app-store/submitting/)
- [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)
- [Required reason APIs](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), especially 2.1 (review access), 4.2 (functionality), 5.1 (privacy), and 5.2.2 (third-party services).

## Image/reader build update — 2026-11-21

Build 2 adds monochrome EPUB images and local Readability extraction. 133 Swift tests and four DOM extraction tests pass; Release iOS/extension and Mac-tool builds pass. A signed development archive was created and installed on the paired phone. App Store export is blocked by Xcode reporting `No Accounts` and missing distribution profiles for the main app and share extension, despite the owner's reported membership approval. Refresh/sign in to the approved account in Xcode, then retry distribution export. No TestFlight upload has occurred.

## PDF sharing update — 2026-11-21

Build 3 registers explicit PDF share and Open In support. Conversion is local: native PDF text, Apple Vision OCR for scans, and monochrome page images. The signed app and extension archive build passed, 137 Swift tests and four webpage tests passed, and a generated-plist test matched PDFs while preserving URL/text/webpage sharing. Build 3 was installed and launched on the connected iPhone. Safari's physical share-sheet UI and e-reader PDF-derived article display still need user verification.

## First TestFlight upload — 2026-11-25

Paperboy 0.1 (101.1), built from `92392f7`, completed the [Publish TestFlight run](https://github.com/mawildoer/paperboy/actions/runs/45760290187). All 137 Swift tests, four extraction tests, and generated-plist share checks passed. Xcode created signing assets through the API, archived the app and extension, cloud-signed the distribution, and reported a successful upload.

The independent [Apple status validation](https://github.com/mawildoer/paperboy/actions/runs/45760699236), introduced in `521eaf3`, confirmed processing `VALID`, internal state `READY_FOR_BETA_TESTING`, and external state `READY_FOR_BETA_SUBMISSION`. The updated normal [CI run](https://github.com/mawildoer/paperboy/actions/runs/45760676858) also passed. [Manage the build in App Store Connect](https://appstoreconnect.apple.com/apps/6838137167/testflight). Internal tester/group enrollment and physical-device testing were not performed by these checks.

Non-blocking warnings for build 101.1: a spare, unassigned legacy icon exists in the icon asset directory; App Intents metadata is skipped because the app does not use that framework; the runner's iOS 26.5 SDK was accepted but triggered Apple's April 2027 SDK warning. CI was subsequently moved to Xcode 27.2 with pre-build and archive SDK checks.


## 2026-11-25 developer-device update

Medium now supports Safari sharing and the signed-in Following page, with local
extraction and explicit paywall-preview rejection. No RSS subscription mode was
added. A real Medium account sign-in and member-story fetch remain to be checked.

The Debug app was signed using the existing desktop-session Xcode helper and
installed directly over USB on the attached iPhone. It sent the final 5,530,768-byte
X3 firmware over Bluetooth, then logged a successful changed-version check for
`0.2.0-paperboy` after reboot and a normal article sync. The reader had received
one USB bootstrap app-slot installation first. The app was relaunched normally
and remains installed; this validation did not depend on TestFlight.

145 shared Swift tests and seven DOM extraction tests passed, as did the PDF/share
registration check and the signed Debug app/extension build. The normal CI run
for Medium/updater commit `628db57` passed on Xcode 27.2. The split TestFlight job
initially lacked XcodeGen; `698212b` restores its installation and isolates article
sync from firmware replies. The corrected TestFlight run
[45767837037](https://github.com/mawildoer/paperboy/actions/runs/45767837037)
subsequently completed successfully. The user explicitly preferred the USB
developer build for that update and requested not to wait for the full
TestFlight cycle.


## 2026-11-26 Touched library, Bump, and search

The app adds an always-visible metadata search bar. Query tokens can match title,
author, and source across fields; normalization handles case/accents and small
misspellings/transpositions. Article bodies and previews are not searched. While
searching, results replace the reader/account sections so matches are visible.

Loaded/locked articles have a separate Bump button. Pending promotions persist
across launches, are sent after any necessary upload, and clear only on a matching
acknowledgment. No EPUB bytes or reading progress are rewritten. Bump does not
change load/read state or publication/arrival dates. The nonce order follows tap
order even within one second. Existing v1 firmware continues ordinary sync/OTA;
bumps wait for v2 firmware (Paperboy 0.3.0).

Local validation: 153 Swift tests, Mac CLI build, and Release iOS app/extension
build passed. Tests cover metadata search, persistent/coalesced requests, stale
acknowledgments, upload-before-bump ordering, legacy firmware, and exact frame
bytes. User requested TestFlight distribution followed by Bluetooth firmware
installation this time; no USB developer deployment is part of this update.

App commit `6b8780e` passed [CI](https://github.com/mawildoer/paperboy/actions/runs/45909891845)
and [TestFlight publication](https://github.com/mawildoer/paperboy/actions/runs/45909891317).
Build **107.1** was archived with Xcode/iOS SDK 27.2 for the app and extension,
uploaded, and confirmed `VALID` and ready for configured internal testers by
Apple's API. Installation and the subsequent Bluetooth firmware update remain
human device checks; CI success does not establish either result.

Companion firmware [paperboy-v0.3.0](https://github.com/mawildoer/crosspoint-reader/releases/tag/paperboy-v0.3.0),
source `77d25af`, passed branch and [release CI](https://github.com/mawildoer/crosspoint-reader/actions/runs/45911582421).
The updater's latest-release endpoint selects it. All downloaded asset checksums
matched; esptool validated the image's internal checksum and hash. The ESP32-C3
image fits the OTA slot, contains runtime version `0.3.0-paperboy`, and has SHA-256
`2891b36182953390c7ece07dac71da378874a1fb179ed233476419fe89c9d014`.
On the phone, install TestFlight build 107.1, then use **Settings → Update reader
over Bluetooth** with the reader in Library and USB-powered or above 30% battery.
After reboot, confirm Paperboy reports `0.3.0-paperboy`, then check Bump order,
partially read article resume, and the three Library views and sleep artwork.

## Automatic and resumable firmware updates

The main page places Update beside the installed firmware version. Settings has
Automatically update, enabled by default and decoded safely from older settings.
Firmware work waits for article sync instead of cancelling it. Stable releases
are compared numerically; automatic work never downgrades or replaces an unknown
development build. Metadata is cached for six hours and the verified image is
cached across launches, so repeat syncs do not redownload it. Normal failures back
off for an hour; partial transfers can continue at a later sync after a one-minute
minimum interval. A long window may continue a partial transfer immediately;
failed attempts retain the hourly backoff even if a partial stage exists.

The existing refresh and processing jobs are reused. iOS chooses when background
jobs run; short windows stage at most 256 KiB on protocol 3 readers, then pause.
The complete actual file is validated and committed only in a foreground or
processing window. Processing tasks run after article work and handle expiration;
Bluetooth restoration can continue staging at later connections. Turning the
option off cancels automatic work before commit. A commit already in progress
still finishes and is verified. See Apple's [background-task guidance](https://developer.apple.com/documentation/backgroundtasks/bgprocessingtask).

Protocol 3 reader firmware stores a checked image identity, offset and prefix CRC
on SD. Resume and pause acknowledgments are verified against the phone's image;
the reader rereads the full actual SD file before commit. Pending confirmation is
written atomically to the app's support directory before the commit command;
failure to save prevents commit. Relaunch/reconnect verifies the expected changed
version rather than treating acceptance or a disconnect as success. The first
upgrade from older Bluetooth firmware needs a complete window to add resume
support; no new USB bootstrap is required.

Explicit commit rejections clear pending confirmation and release maintenance;
only ambiguous commit delivery keeps the record. Pause also releases a validated
stage after cancellation or a failed confirmation-record write. Host checks run
the real receiver handlers and verify immediate article transfer after such a
pause, preserved offsets after final-checkpoint short writes/rename failures,
and low-battery commit rejection followed by resume and a later accepted commit.

The larger, upright Paperboy mark and dark text on white are in firmware 0.3.1
and carried forward in 0.4.0. The logo remains in flash (18,432 bytes) at the
human's discretion; it adds no bitmap-buffer RAM allocation or SD dependency.

Local validation for this change: 170 shared Swift tests, Release iOS app and
extension, Mac CLI, share/document registration, and actual settings-decoder
migration/disabled-state persistence checks passed. The actual firmware receiver
host checks pass across checkpoint failures and recovery into article sync.
Four independent reviews and one targeted follow-up covered both sides of the
wire contract. Pause/validated-state handling, preservation after final metadata
write failure, and definitive commit rejection findings were resolved; no verified
finding remains. The new repository was also exercised against the live 0.3.1
GitHub release and its disk cache, with verified image integrity.
TestFlight delivery and the 0.4.0 firmware release are checked separately before
reporting availability. Physical interruption/resume and display checks remain
human device checks; no USB app install or reader flash is part of this update.
