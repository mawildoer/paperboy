// Paperboy wrapper: parse an inert DOM, preserve figures/captions, and never execute page scripts.
function paperboyReaderHTML(html, pageURL) {
  const doc = new DOMParser().parseFromString(html, "text/html");
  const host = new URL(pageURL).hostname;
  const medium = host === 'medium.com' || host.endsWith('.medium.com') ||
    !!doc.querySelector('meta[property="al:ios:app_name"][content="Medium"], meta[property="al:android:app_name"][content="Medium"]');
  if (medium) {
    doc.querySelectorAll('[hidden], [aria-hidden="true"], [style*="display: none"], [style*="display:none"]').forEach(n => n.remove());
    const articleText = (doc.querySelector('article')?.textContent || '').replace(/\s+/g, ' ');
    const wall = Array.from(doc.querySelectorAll('[data-testid="paywall"], [data-testid="paywall-modal"], [data-testid="paywall-container"], #paywall, .paywall'))
      .some(n => !n.closest('[hidden], [aria-hidden="true"], [style*="display: none"], [style*="display:none"]'));
    if (wall || /(?:read (?:the rest|this story|more) of this story|become a member to (?:read|continue)|(?:unlock|get unlimited access to) (?:the rest of )?this story)/i.test(articleText)) {
      return {error: 'medium-access-required'};
    }
  }
  doc.querySelectorAll("base").forEach(n => n.remove());
  const base = doc.createElement("base"); base.href = pageURL; doc.head.prepend(base);
  doc.querySelectorAll('nav, aside, footer, form, button, iframe, [hidden], [aria-hidden="true"], [role="navigation"], [role="complementary"], [role="dialog"], .advertisement, .ad-container, .ad-slot, .related-posts, .related-articles, .recommended-articles, .recommended-posts, .read-next, .newsletter-signup, .subscription-widget, .cookie-banner, #comments').forEach(n => n.remove());
  doc.querySelectorAll("img").forEach(img => {
    const lazy = img.getAttribute("data-src") || img.getAttribute("data-lazy-src");
    if (lazy) img.setAttribute("src", lazy);
    const src = img.getAttribute("src");
    if (src) { try { img.setAttribute("src", new URL(src, pageURL).href); } catch (_) {} }
  });
  const reader = new Readability(doc, {charThreshold: 100, maxElemsToParse: 30000});
  const article = reader.parse();
  if (!article || !article.content || article.textContent.trim().length < 60) return null;
  const escape = text => (text || "").replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const metadata = '<title>' + escape(article.title) + '</title>' +
    '<meta name="author" content="' + escape(article.byline) + '">' +
    '<meta property="og:site_name" content="' + escape(article.siteName) + '">' +
    '<meta property="article:published_time" content="' + escape(article.publishedTime) + '">';
  return {html: '<html><head>' + metadata + '</head><body><article>' + article.content + '</article></body></html>',
    title: article.title || "", author: article.byline || "", source: article.siteName || "", date: article.publishedTime || ""};
}
