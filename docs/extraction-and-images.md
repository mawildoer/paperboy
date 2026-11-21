# Reader extraction and images

Mozilla Readability is pinned at `ab4027a8b37669745016869a37a504727992b2ba` from https://github.com/mozilla/readability. The Apache 2.0 license and NOTICE are bundled with its source under `PaperboyCore/Resources`. Safari's share script bundles the same code. The app runs it in an inert detached DOM without executing the article's scripts. HTML is still sanitized into the reader's restricted XHTML vocabulary.

Images are resolved relative to the source URL, capped at twelve, fetched sequentially (6 MB input limit), downsampled on the phone, and stored as losslessly compressed 1-bit grayscale PNGs in the EPUB. Charts/diagrams get up to 1056px width and 1584px longest edge, with color lines mapped to black. Photos get at most 320px width and ordered dithering. Limits: 96 KiB per chart, 24 KiB per photo, 512 KiB for all images in an article. PNG/JPEG and other ImageIO-decodable raster formats are supported; Safari sharing attempts to capture up to six visible canvas/SVG figures locally before extraction (1.5 second capture window); cross-origin canvas restrictions and complex SVGs can prevent capture. Images loaded from a URL must still be raster formats that ImageIO decodes. Captions and alt text survive independently of image downloads.

Two colors necessarily merge series that differ only by color; labels, symbols, and line patterns are preferable. The reader can scale figures to its display width, so very dense charts still need device testing. Automatic classification uses metadata hints and a sparse pale-background heuristic, not semantic understanding of a chart.

No LLM or cloud extraction is enabled. A future explicit visual fallback could use rendered-page/PDF images plus text/OCR to recover difficult layouts. It would need user consent for uploads, provider configuration, a cost limit, prompt-injection handling, preservation of original figures, and checks against omitted text or invented chart values. PDFs need their own import path; this change does not add PDF support.

## Verification

133 Swift tests and four DOM extraction tests pass. Coverage includes the actual WebKit bridge, no publisher script execution, removal of ads/recommendations, lazy/responsive image URLs, exclusion of tracking pixels, data-URL image preparation, compressed PNG decoding, photo size limits, EPUB manifests/assets, and malformed input. An example 1200×700 chart shrank from about 52 KiB to 3.5 KiB at 1056px width. Physical e-reader rendering and Safari SVG/canvas capture still need device checks.

Processing applies to new imports and fetched articles. Previously cached EPUBs are not retroactively rewritten by this update. Cloud extraction, OCR, PDF import, and automatic refresh of already-cached EPUBs remain separate work.
