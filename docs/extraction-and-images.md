# Reader extraction and images

Mozilla Readability is pinned at `ab4027a8b37669745016869a37a504727992b2ba` from https://github.com/mozilla/readability. The Apache 2.0 license and NOTICE are bundled with its source under `PaperboyCore/Resources`. Safari's share script bundles the same code. The app runs it in an inert detached DOM without executing the article's scripts. HTML is still sanitized into the reader's restricted XHTML vocabulary.

Images are resolved relative to the source URL, capped at twelve, fetched sequentially (6 MB input limit), downsampled on the phone, and stored as losslessly compressed 1-bit grayscale PNGs in the EPUB. Charts/diagrams get up to 1056px width and 1584px longest edge, with color lines mapped to black. Photos get at most 320px width and ordered dithering. Limits: 96 KiB per chart, 24 KiB per photo, 512 KiB for all images in an article. PNG/JPEG and other ImageIO-decodable raster formats are supported; Safari sharing attempts to capture up to six visible canvas/SVG figures locally before extraction (1.5 second capture window); cross-origin canvas restrictions and complex SVGs can prevent capture. Images loaded from a URL must still be raster formats that ImageIO decodes. Captions and alt text survive independently of image downloads.

Two colors necessarily merge series that differ only by color; labels, symbols, and line patterns are preferable. The reader can scale figures to its display width, so very dense charts still need device testing. Automatic classification uses metadata hints and a sparse pale-background heuristic, not semantic understanding of a chart.

## PDF sharing

Safari/Files can send a PDF attachment or file URL. The share extension uses an explicit PDF UTI activation predicate and copies the temporary provider file into its App Group before the provider callback returns. The main app also registers PDF Open In support and copies security-scoped documents while access is held. Queued PDFs are content-hashed so sharing the same bytes twice does not create duplicate articles.

Conversion happens in the main app on a worker task. PDFKit extracts native text; pages with little native text use local Apple Vision OCR. Core Graphics renders each page to a compact monochrome PNG, keeping chart/table geometry without having OCR reconstruct it. Text is included separately for reflow. No PDF pages are uploaded to a service. PDFKit text/OCR reading order can be imperfect for complex columns and formulas; page images remain available.

Limits are one PDF at a time, 20 MB input, 20 pages, and 512 KiB of processed images. Oversized, locked, copy-restricted, invalid, or unrenderable documents return a visible import error rather than silently dropping pages. Open Paperboy after sharing to finish conversion and sync. Successful or duplicate imports remove the queued copy; failed imports are retried up to three times before the temporary queue item is removed. The original Safari/Files document is untouched.

Cloud/LLM extraction remains disabled, in accordance with the on-device-only requirement.

## Verification

137 Swift tests and four DOM extraction tests pass. PDF tests cover native text, scanned-page OCR, monochrome EPUB assets, stable-identity temporary-file handoff, malformed/oversized input, and page-limit rejection. A generated-plist test verifies PDF, link, text and webpage activation plus main-app document registration. Coverage includes the actual WebKit bridge, no publisher script execution, removal of ads/recommendations, lazy/responsive image URLs, exclusion of tracking pixels, data-URL image preparation, compressed PNG decoding, photo size limits, EPUB manifests/assets, and malformed input. An example 1200×700 chart shrank from about 52 KiB to 3.5 KiB at 1056px width. Physical e-reader rendering and Safari SVG/canvas capture still need device checks.

Processing applies to new imports and fetched articles. Previously cached EPUBs are not retroactively rewritten by this update. Cloud extraction and automatic refresh of already-cached EPUBs remain separate work.
