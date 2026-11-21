# iPhone app

The app has been built and installed on an iPhone. Its shared package has host tests; live content integrations and background delivery still need broader release testing.

Generate the Xcode project with `xcodegen generate` in this directory and open `Paperboy.xcodeproj`. Full Xcode is required. `Package.swift` is only a macOS typecheck helper, not the app build.

The `Paperboy` target contains the app and links `../PaperboyCore`. The `PaperboyShare` target provides the share sheet and Safari page extraction, using the same app group as the app. Their Info.plist and entitlement files are generated from `project.yml`.

The spec retains the current development bundle identifiers and team. To distribute, use a paid Apple Developer team, register the app and extension identifiers plus the shared app group, and create matching profiles. See [release preparation](../docs/app-store-release.md).

The app's log is stored locally and can contain article titles, URLs, reader identifiers, and cookie metadata. Cookie values are not logged. Review diagnostic logging before release.
