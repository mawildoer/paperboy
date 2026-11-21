# Paperboy privacy policy — release draft

This document describes the current development implementation. Review and finalize it, provide a support contact, publish a stable policy URL, and link it in the app before distribution.

Paperboy stores saved articles, reading/sync status, preferences, and diagnostic logs on your device. Signing into a publisher uses that publisher's website inside an in-app browser. Session cookies are stored using the system web and HTTP cookie stores so the app can retrieve content available to your account. Credentials are not sent to a Paperboy-operated server.

The current project has no Paperboy backend, advertising SDK, or analytics SDK. Requests to publishers and other sites you choose are sent directly to those sites and are governed by their privacy policies. Embedded publisher pages can have their own analytics, cookies, and data collection; those are part of the release privacy review, not a guarantee of this draft.

Articles selected for the reader, including their compact black-and-white images, titles/authors/source information, and reading status are exchanged over a paired encrypted Bluetooth connection with your e-reader. Once delivered, the reader stores its own copy on its SD card. The Safari share extension places shared page data in a local App Group container for the main app to import.

Local diagnostic logs can contain article titles, source URLs, Bluetooth device identifiers, HTTP status codes, and cookie names/domains/expiry metadata. They do not intentionally record cookie values or passwords. Logs can become accessible to anyone with access to a development device or a diagnostic export; review logging and export behavior before public release.

You can sign out of publishers and forget the reader in Settings. Signing out does not imply that downloaded articles or reader copies have been removed. The release must document and validate removal of cached articles, logs, and shared inbox items. Device backups and publisher account records are controlled separately by Apple and the publisher.

Support/contact: to be finalized by the app owner before release. This draft is not an App Store privacy-label submission or a representation that publisher integrations are approved.

Reader-mode extraction and image conversion run locally. Source images are requested directly from their hosting sites, using applicable publisher session cookies. No LLM or cloud document-processing service is enabled.

PDFs shared from Safari/Files are copied into the local App Group inbox, then processed on the device with PDFKit, Core Graphics, and Apple Vision OCR. Reflowable text and monochrome page images are sent only to the paired reader. No PDF pages or OCR inputs are uploaded to an AI service. Temporary queue files are removed after a successful/duplicate import, or after three unsuccessful import attempts; the original shared file is not modified.
