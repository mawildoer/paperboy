# Reader extraction and images

Mozilla Readability is pinned at `ab4027a8b37669745016869a37a504727992b2ba` from https://github.com/mozilla/readability. The Apache 2.0 license and NOTICE are bundled with its source under `PaperboyCore/Resources`. Safari's share script bundles the same code. The app runs it in an inert detached DOM without executing the article's scripts. HTML is still sanitized into the reader's restricted XHTML vocabulary.

Images are resolved relative to the source URL, capped at twelve, fetched sequentially (6 MB input limit), downsampled on the phone, and stored as losslessly compressed 1-bit grayscale PNGs in the EPUB. Charts/diagrams get up to 1056px width and 1584px longest edge, with color lines mapped to black. Photos get at most 320px width and ordered dithering. Limits: 96 KiB per chart, 24 KiB per photo, 512 KiB for all images in an article. PNG/JPEG and other ImageIO-decodable raster formats are supported; Safari sharing attempts to capture up to six visible canvas/SVG figures locally before extraction (1.5 second capture window); cross-origin canvas restrictions and complex SVGs can prevent capture. Images loaded from a URL must still be raster formats that ImageIO decodes. Captions and alt text survive independently of image downloads.

Two colors necessarily merge series that differ only by color; labels, symbols, and line patterns are preferable. The reader can scale figures to its display width, so very dense charts still need device testing. Automatic classification uses metadata hints and a sparse pale-background heuristic, not semantic understanding of a chart.

## Web articles and ad controls

The web extractor uses local reader-mode heuristics. NYT also has a structured-data fallback. Paperboy removes ad slots and skip links before reader mode flattens them into text, then removes standalone ad labels from the generated article. A sentence discussing advertising or quoting a skip link remains readable.

At launch, Paperboy checks old previews that begin with ad controls and rebuilds the affected phone EPUB and preview from the local chapter. This keeps images, article identity and library state. Copies already on the e-reader keep their reading position. A subsequent fresh transfer uses the cleaned file.

## Apple News

Open a story in Apple News, choose **Share → Paperboy**, then let Paperboy sync as usual. Paperboy follows the share link to the publisher’s web edition and uses the same import and signed-in sources as a direct publisher share. Sharing both links queues a single article. If Apple supplies no publisher link, Paperboy explains how to share from Safari when a web edition exists.

Access depends on what the publisher makes available on the web. Apple News+ access inside News does not grant a separate publisher login. Apple’s documented News API is for publishers. Paperboy supports individual shares and does not monitor a personal Following or Today feed. [Apple News API](https://developer.apple.com/documentation/applenewsapi)

## The Economist

The Economist uses its persistent in-app WebKit session. Selecting **Use this session** enables front-page discovery. Foreground refreshes and scheduled website fetches discover dated story links in front-page order. The per-fetch limit and library retention window apply. Fetched items appear in the phone library, and shared items enter the reader load queue.

Safari can supply the readable page directly. A URL-only share, including one from The Economist app, opens in the Paperboy website session. A gift URL retains its query when sent to the publisher. The library uses the story URL without its tracking or gift parameters for deduplication. A publisher sign-in, subscription prompt or verification screen can require action in the website session.

## Medium

Share a readable Medium page from Safari, or sign into Medium inside Paperboy to
monitor its rendered Following page. There is no separate RSS subscription mode.
The signed-in WebKit session loads story pages; local Readability extracts text,
author, publication time, figures and captions. Explicit visible member-access
walls are rejected, and feed teasers are not used as article bodies. A membership
still needs access to that story. Hidden paywall templates and the label
“Member-only story” alone do not reject an otherwise readable article.

Following discovery depends on Medium's current page markup and session cookies;
it does not use a supported public feed API. Live account login, member-only access,
custom-domain behavior, and background refresh need validation with a real account.
Do not promise every subscription or all historical stories; discovery uses the
stories currently loaded on Following. Browser sharing remains available.

## PDF sharing

Safari/Files can send a PDF attachment or file URL. The share extension uses an explicit PDF UTI activation predicate and copies the temporary provider file into its App Group before the provider callback returns. The main app also registers PDF Open In support and copies security-scoped documents while access is held. Queued PDFs are content-hashed so sharing the same bytes twice does not create duplicate articles.

Conversion happens in the main app on a worker task. PDFKit extracts native text; pages with little native text use local Apple Vision OCR. Core Graphics renders each page to a compact monochrome PNG, keeping chart/table geometry without having OCR reconstruct it. Text is included separately for reflow. No PDF pages are uploaded to a service. PDFKit text/OCR reading order can be imperfect for complex columns and formulas; page images remain available.

Limits are one PDF at a time, 20 MB input, 20 pages, and 512 KiB of processed images. Oversized, locked, copy-restricted, invalid, or unrenderable documents return a visible import error rather than silently dropping pages. Open Paperboy after sharing to finish conversion and sync. Successful or duplicate imports remove the queued copy; failed imports are retried up to three times before the temporary queue item is removed. The original Safari/Files document is untouched.

Cloud/LLM extraction remains disabled, in accordance with the on-device-only requirement.

## Verification

PDF tests cover native text, scanned-page OCR, monochrome EPUB assets, stable-identity temporary-file handoff, malformed/oversized input, and page-limit rejection. A generated-plist test verifies PDF, link, text and webpage activation plus main-app document registration. Coverage includes the actual WebKit bridge, no publisher script execution, removal of ads/recommendations, lazy/responsive image URLs, exclusion of tracking pixels, data-URL image preparation, compressed PNG decoding, photo size limits, EPUB manifests/assets, and malformed input. An example 1200×700 chart shrank from about 52 KiB to 3.5 KiB at 1056px width. Physical e-reader rendering and Safari SVG/canvas capture still need device checks.
