# App Store preparation

Status: preparation only. No build has been submitted to App Store Connect or App Review.

Local verification on 2026-11-20: 126 shared tests passed; the Mac sync tool built; the unsigned Release iOS app and share extension built; both privacy manifests were present in the built bundles. Distribution signing, archive export, and Apple validation have not been performed.

## Prepared

- Separate iOS app, share extension, shared Swift package, and Mac test-tool source.
- XcodeGen project, 1024px opaque icon, usage descriptions, version/build settings, and App Group entitlements.
- Privacy manifests for the app and share extension. The app declares local UserDefaults use (`CA92.1`). Neither includes developer tracking or developer-collected data declarations; these must be re-audited before submission, including embedded publisher web pages.
- CI runs package tests, builds the Mac tool, and builds the Release iOS app/extension without signing.
- `TEAM_ID=YOUR_PAID_TEAM ./scripts/archive.sh` creates a signed archive. This script does not upload or submit anything.

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
