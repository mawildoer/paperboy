# App Store preparation

Status: preparation only. No build has been submitted to App Store Connect or App Review.

Local verification on 2026-11-20: 126 shared tests passed; the Mac sync tool built; the unsigned Release iOS app and share extension built; both privacy manifests were present in the built bundles. Distribution signing, archive export, and Apple validation have not been performed.

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

For an equivalent local upload, set the three `ASC_*` variables and a new `BUILD_NUMBER`, select full Xcode using `DEVELOPER_DIR`, then run `bash scripts/testflight.sh`. Optional `TEAM_ID` and `TESTFLIGHT_OUTPUT` override the team and output directory. The script refuses to replace an existing archive and stops if archiving or uploading fails.

To recheck a build that was already uploaded, manually run **Validate TestFlight** on `main` and enter its build number. This workflow only reads Apple status; it does not create another build or send invitations. It uses the same three secrets, signs short-lived API tokens locally on the runner, prints processing/beta states and the app link, and removes its private-key file on exit. If Apple processing takes longer than 20 minutes, rerun this status check rather than uploading the same build again.

References: [Apple's cloud-signing automation](https://developer.apple.com/videos/play/wwdc2021/10204/), [App Store Connect API setup](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/), and [upload processing](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/).

## Remaining gates

1. **Distribution account.** The local Xcode configuration was a free Personal Team on 2026-11-20. App Store and TestFlight require Apple Developer Program membership; enrollment and agreements need the account holder. Confirm the distribution team and retain or migrate bundle identifiers deliberately.
2. **App identity and capabilities.** Register `app.paperboy.readerc67aad`, its `.share` extension, and `group.app.paperboy.readerc67aad` with the distribution team. If changing them, update both code constants, the project spec, and entitlement files together. Create the App Store Connect app record. Verify name availability before branding is finalized.
3. **Content access permissions.** Substack and NYT use undocumented/private endpoints and signed-in web views. Verify that public distribution is permitted under each service's terms and obtain authorization if necessary. A paid reader subscription alone does not establish distribution permission. Keep NYT out of launch claims until login and fetching are verified. Consider a first release centered on user-initiated sharing of permitted pages if direct integrations cannot be cleared.
4. **Privacy.** Review [the draft policy](privacy-draft.md), publish a stable privacy-policy URL, link it in the app, and fill App Store Connect privacy answers from a final audit. Recheck manifests against the archive privacy report. Audit logs, cookies, the share extension, publisher pages, retention, device transfer, and removal of local data. Establish user-facing controls/documentation for clearing cached articles and logs; current sign-out should not be assumed to remove all downloaded content.
5. **Product validation.** Test fresh installs, denied permissions, expired sign-ins, custom-domain subscriptions, missing content access, Bluetooth reconnect/restoration, reader sleep, background fetching, large transfers, interrupted sync, and the share extension. Confirm unfinished articles resume and are not deleted during synchronization. Do not promise continuous or scheduled background availability.
6. **Reviewer access.** Prepare sample content you have rights to share, clear setup steps, and an explanation of the hardware dependency. Arrange a reviewable path or demo approach acceptable to App Review; a physical X3 and private subscriptions cannot be assumed available to reviewers.
7. **Listing.** Supply accurate screenshots, description, support URL/contact, privacy URL, age rating, content-rights answers, encryption declarations, territories/pricing, and reviewer notes. Do not assume the current encryption flag is a completed export-compliance assessment.
8. **Release.** Archive and validate with the paid team, upload through Xcode Organizer, test the processed build through TestFlight, then complete App Review. No distribution key, password, certificate, or provisioning profile belongs in Git.

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
