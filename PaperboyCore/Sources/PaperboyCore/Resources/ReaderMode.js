const economistAccessError = 'economist-access-required';
const economistBody = [
  'article', '[itemprop~="articleBody"]', '[data-test-id="ArticleBody" i]',
  '[data-test-id="article-body" i]', '[data-testid="article-body" i]',
].join(', ');
const inertContent = 'script, template, noscript, textarea, style, link[rel~="stylesheet" i]';
const hiddenContent = '[hidden], [inert], [aria-hidden="true" i], dialog:not([open]), details:not([open])';

function paperboyIsEconomist(address) {
  try {
    const url = new URL(address);
    return /^https?:$/.test(url.protocol) && /(^|\.)economist\.com\.?$/.test(url.hostname);
  } catch (_) { return false; }
}

// Removing a hidden primary body would leave an apparently readable preview behind.
function containsWithheldBody(node) {
  const selector = '[itemprop~="articleBody"], [data-test-id="ArticleBody" i], [data-testid="article-body" i], .paywalled-content, .subscriber-only-content';
  return node.matches(selector) || !!node.querySelector(selector);
}

function concealed(style) {
  return style.display === 'none' || /^(hidden|collapse)$/.test(style.visibility) ||
    style.opacity === '0' || style.getPropertyValue('content-visibility') === 'hidden';
}

// Readability would remove the styles that limit the reader to part of this text.
function obscuresText(style, node, rendered) {
  const clamp = style.getPropertyValue('-webkit-line-clamp');
  if ((clamp && clamp !== 'none') || /blur\(/i.test(style.filter) ||
      (style.clipPath && style.clipPath !== 'none') || (style.clip && style.clip !== 'auto')) return true;
  if (!/hidden|clip/.test(style.overflowY || style.overflow)) return false;
  return rendered ? node.scrollHeight > node.clientHeight : !!(style.height || style.maxHeight);
}

// Both Safari and the signed-in WKWebView inspect styles in the live document, before
// serializing. Keep the node lists aligned when removing a hidden ancestor from the copy.
function paperboyRenderedClone(doc, visit) {
  const economist = paperboyIsEconomist(doc.URL);
  const originals = doc.querySelectorAll('*');
  if (economist && (originals.length > 30000 ||
      Array.from(doc.querySelectorAll('link[rel~="stylesheet" i]')).some(link => !link.disabled && !link.sheet))) return null;
  const clone = doc.cloneNode(true);
  const copies = clone.querySelectorAll('*');
  for (let i = 0; i < originals.length && i < 30000; i++) {
    const original = originals[i], copy = copies[i];
    if (!copy.isConnected) continue;
    if (economist && original.matches(inertContent)) { copy.remove(); continue; }
    if (original.closest('head')) continue; // title and metadata are non-rendering by design
    const style = doc.defaultView.getComputedStyle(original);
    if (concealed(style) || (economist && original.matches(hiddenContent))) {
      if (economist && containsWithheldBody(original)) return null;
      copy.remove();
      continue;
    }
    if (economist && obscuresText(style, original, true)) {
      if (original.closest(economistBody) && (original.matches('p') || original.querySelector('p'))) return null;
      copy.remove();
      continue;
    }
    if (original.localName === 'img' && original.currentSrc) copy.setAttribute('src', original.currentSrc);
    if (visit) visit(original, copy);
  }
  return clone;
}

function paperboyEconomistSnapshot(doc) {
  if (!paperboyIsEconomist(doc.URL)) return {error: economistAccessError};
  const clone = paperboyRenderedClone(doc);
  return clone?.body ? paperboyReaderHTML(clone.documentElement.outerHTML, doc.URL) : {error: economistAccessError};
}

// Only the visible editorial DOM is a source of body text. A detached document cannot
// resolve publisher stylesheets. Such pages need a rendered snapshot from the user's session.
function prepareEconomistArticle(doc, address) {
  const url = new URL(address);
  if (/^(?:myaccount|account|id|auth|login)\./i.test(url.hostname) ||
      /\/(?:log-?in|sign-?in|authenticate|challenge|cdn-cgi)(?:\/|$)/i.test(url.pathname) ||
      doc.querySelector('style:not(:empty), link[rel~="stylesheet" i]')) return false;

  doc.querySelectorAll(inertContent).forEach(node => node.remove());
  for (const node of doc.querySelectorAll(hiddenContent + ', [style]')) {
    if (node.matches(hiddenContent) || concealed(node.style)) {
      if (containsWithheldBody(node)) return false;
      node.remove();
    } else if (obscuresText(node.style, node, false)) {
      if (node.closest(economistBody) && (node.matches('p') || node.querySelector('p'))) return false;
      node.remove();
    }
  }
  if (!doc.body) return false;
  const wall = [
    '[data-testid*="paywall" i]', '[data-test-id*="paywall" i]', '[id*="paywall" i]',
    '.paywall', '.paywall-container', '.paywall-overlay', '.subscription-wall', '.regwall',
    '.tp-modal', '.tp-backdrop', '[aria-modal="true"]',
    'dialog[open]', '#challenge-form', 'input[type="password"]', 'iframe[src*="paywall" i]',
  ].join(', ');
  if (doc.querySelector(wall)) return false;
  const challenge = /^(?:just a moment\b|checking your browser\b|verify (?:that )?you are human\b|enable javascript and cookies\b|access denied\b|(?:log in|sign in|login)(?:$|\s*[|–-]| to (?:your account|the economist)))/i;
  const normalized = node => (node.textContent || '').replace(/\s+/g, ' ').trim();
  if ([doc.title, ...Array.from(doc.querySelectorAll('h1'), normalized)].some(text => challenge.test(text))) return false;

  // Subscription links in the masthead and offers after the article are ordinary furniture.
  doc.querySelectorAll('footer, nav, [role="contentinfo"], [role="navigation"], .article__footer, [data-test-id="ArticleFooter" i]').forEach(node => node.remove());
  const gateCopy = [
    /^(?:please )?(?:subscribe|register|sign in|log in|create (?:a free |an? )account)\b.{0,60}?\bto (?:continue|keep reading|read|unlock|access)\b/i,
    /^(?:to )?(?:continue reading|read the (?:rest|full (?:article|story)))\b.{0,60}?\b(?:subscribe|register|log in|sign in|subscription)\b/i,
    /^(?:(?:the rest of )?this (?:article|story|content) is|available) (?:only |exclusively )?(?:available )?(?:for|to) subscribers\b/i,
    /^you(?: have|['’]ve) (?:reached|used|read)\b.{0,40}?\bfree article/i,
    /^(?:unlock|get (?:full )?access to) (?:this|the full) (?:article|story)\b/i,
  ];
  for (const node of doc.body.querySelectorAll('p, h1, h2, h3, section, div, form, span, a, button, aside, dialog')) {
    // Check the prompt itself, including inline markup, without flattening the whole page.
    if (node.childElementCount > 0 && node.querySelector('p, div, section, form, h1, h2, h3')) continue;
    const text = normalized(node);
    if (gateCopy.some(pattern => pattern.test(text))) return false;
  }
  if (!doc.title) doc.title = doc.querySelector('h1')?.textContent || '';
  doc.querySelectorAll('header, aside, [role="complementary"], .subscription-widget, [data-testid*="teaser" i], [data-test-id*="teaser" i], .article__teaser, .article-preview, .teaser').forEach(node => node.remove());
  const article = doc.querySelector(economistBody);
  if (!article || article.querySelectorAll('p').length < 2) return false;
  doc.body.replaceChildren(article);
  return true;
}

// Paperboy wrapper: parse an inert DOM, preserve figures/captions, and never execute page scripts.
function paperboyReaderHTML(html, pageURL) {
  const doc = new DOMParser().parseFromString(html, "text/html");
  const savedError = doc.head.querySelector('meta[name="paperboy-access-error"]')?.content;
  if (savedError === economistAccessError || savedError === 'medium-access-required') return {error: savedError};
  const savedOrigin = doc.head.querySelector('meta[name="paperboy-reader-origin"]')?.content;
  const economistURL = paperboyIsEconomist(pageURL) ? pageURL : paperboyIsEconomist(savedOrigin) ? savedOrigin : null;
  if (economistURL && !prepareEconomistArticle(doc, economistURL)) return {error: economistAccessError};
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
  // Reader mode can flatten ad slots and accessibility links into article paragraphs.
  doc.querySelectorAll('[aria-label="advertisement" i], [aria-roledescription="advertisement" i], [data-ad-slot], [data-ad-unit], [data-testid="ad" i], [data-testid="advertisement" i], [data-testid="ad-slot" i], ins.adsbygoogle').forEach(n => {
    if (!n.matches('html, body, main, article')) n.remove();
  });
  const label = text => (text || '').replace(/\s+/g, ' ').trim().toLowerCase();
  const skipAd = /^(?:skip (?:this )?(?:ad|advertisement)|continue reading (?:after|below) (?:the )?advertisement)$/;
  for (const link of doc.querySelectorAll('a[href^="#"]')) {
    if (skipAd.test(label(link.textContent)) || skipAd.test(label(link.getAttribute('aria-label')))) link.remove();
  }
  // Only standalone text blocks. Preserve editorial sentences, quoted text and figures.
  for (const block of doc.querySelectorAll('p, div, section')) {
    if (block.childElementCount > 3 || block.closest('figure, blockquote, pre, code') ||
        block.querySelector('img, svg, canvas, figure, p, div, section, blockquote, pre, code')) continue;
    const text = label(block.textContent);
    if (text === 'advertisement' || text === 'advertisement skip advertisement' || skipAd.test(text)) block.remove();
  }
  // Drop serialized state and alternate lazy sources before Readability can promote them.
  if (economistURL) {
    for (const node of doc.body.querySelectorAll('*')) {
      for (const name of node.getAttributeNames()) {
        if (name.startsWith('data-') || name.startsWith('on')) node.removeAttribute(name);
      }
    }
  }
  doc.querySelectorAll("img").forEach(img => {
    const lazy = img.getAttribute("data-src") || img.getAttribute("data-lazy-src");
    if (lazy) img.setAttribute("src", lazy);
    const src = img.getAttribute("src");
    if (src) { try { img.setAttribute("src", new URL(src, pageURL).href); } catch (_) {} }
  });
  const reader = new Readability(doc, {charThreshold: 100, maxElemsToParse: 30000});
  const article = reader.parse();
  if (!article || !article.content || article.textContent.trim().length < 60) {
    return economistURL ? {error: economistAccessError} : null;
  }
  const escape = text => (text || "").replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const metadata = (economistURL ? '<meta name="paperboy-reader-origin" content="' + escape(economistURL) + '">' : '') +
    '<title>' + escape(article.title) + '</title>' +
    '<meta name="author" content="' + escape(article.byline) + '">' +
    '<meta property="og:site_name" content="' + escape(article.siteName) + '">' +
    '<meta property="article:published_time" content="' + escape(article.publishedTime) + '">';
  return {html: '<html><head>' + metadata + '</head><body><article>' + article.content + '</article></body></html>',
    title: article.title || "", author: article.byline || "", source: article.siteName || "", date: article.publishedTime || ""};
}
