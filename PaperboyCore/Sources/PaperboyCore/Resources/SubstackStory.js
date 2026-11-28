// Runs in WebKit's isolated content world on the live publication page.
function substackStory(doc) {
  const address = new URL(doc.URL);
  const isHTTPS = url => url.protocol === 'https:' && !url.username && !url.password;
  const isPost = url => isHTTPS(url) && /^\/(?:s\/[^/]+\/)?p\/[^/]+\/?$/.test(url.pathname);
  const substackHost = /(^|\.)substack\.com$/i.test(address.hostname);
  const mobilePost = substackHost && /^\/(?:home\/post\/p-\d+|@[^/]+\/p-\d+|pub\/[^/]+\/p\/[^/]+|app-link\/post)\/?$/.test(address.pathname);
  if (!isHTTPS(address) || (!isPost(address) && !mobilePost)) return null;

  const meta = key => doc.querySelector('meta[property="' + key + '"], meta[name="' + key + '"]')?.content;
  const canonical = doc.querySelector('link[rel~="canonical" i]')?.href || meta('og:url');
  let identity = address;
  if (canonical) {
    try {
      const declared = new URL(canonical, address);
      if (isPost(declared) && (substackHost || declared.origin === address.origin)) identity = declared;
    } catch (_) { /* The landed post URL still identifies the article. */ }
  }
  if (!isPost(identity)) return null;
  identity.search = '';
  identity.hash = '';

  const styleOf = el => doc.defaultView.getComputedStyle(el);
  function hidden(el, style) {
    return el.matches('[hidden], [inert], [aria-hidden="true" i], dialog:not([open]), details:not([open])') ||
      style.display === 'none' || /hidden|collapse/.test(style.visibility) || style.opacity === '0' ||
      style.contentVisibility === 'hidden';
  }
  function visible(el) {
    for (; el; el = el.parentElement) if (hidden(el, styleOf(el))) return false;
    return true;
  }
  function obscured(el, style) {
    const clamp = style.getPropertyValue('-webkit-line-clamp');
    return (clamp && clamp !== 'none') || /blur\(/i.test(style.filter) ||
      (style.clipPath && style.clipPath !== 'none') || (style.clip && style.clip !== 'auto') ||
      (style.maskImage && style.maskImage !== 'none') ||
      (/hidden|clip/.test(style.overflowY) && el.scrollHeight > el.clientHeight + 1);
  }

  const visibleMatch = selector => Array.from(doc.querySelectorAll(selector)).some(visible);
  if (visibleMatch('#challenge-form, iframe[src*="challenges.cloudflare.com"], input[type="password"]')) return null;
  const challenge = /^(?:just a moment|access denied|verify (?:that )?you are human|checking your browser|enable javascript and cookies|sign in|log in)(?:\b|$)/i;
  if (challenge.test(doc.title) || Array.from(doc.querySelectorAll('h1')).some(el => visible(el) && challenge.test(el.innerText.trim()))) return null;
  const gate = /^(?:(?:this (?:post|article|story|content) is|available) (?:only |exclusively )?(?:available )?(?:for|to) (?:paid |paying |founding |free )?(?:subscribers|members)\b|(?:please )?(?:subscribe|sign in|log in|upgrade|become a paid subscriber)\b.{0,55}\bto (?:keep reading|continue|read (?:the rest|the full|this|more)|unlock)\b|continue reading this post for free, courtesy of\b|already a paid subscriber\?)/i;
  const wall = '#paywall, .paywall, .paywall-title, .paywall-overlay, .paywall-container, .paywall-jump, .post-preview, ' +
    '[data-testid*="paywall" i], [data-component-name="Paywall"], [aria-label="Paywall" i]';
  if (visibleMatch(wall) || doc.body.innerText.split(/\n+/).some(line => gate.test(line.trim()))) {
    // A custom publication may offer Substack's first-party sign-in at the wall.
    // Return only its publication name. The app constructs the sign-in URL itself.
    if (!substackHost && doc.querySelector('article.newsletter-post, .dt-post-body')) {
      for (const link of doc.querySelectorAll('a[href*="for_pub="]')) {
        if (!visible(link)) continue;
        let target;
        try { target = new URL(link.href); } catch (_) { continue; }
        const name = target.searchParams.get('for_pub') || '';
        if (target.origin === 'https://substack.com' && !target.username && !target.password &&
            target.pathname === '/sign-in' && /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(name)) {
          return {host: address.hostname, for_pub: name};
        }
      }
    }
    return null;
  }
  if (visibleMatch('[aria-modal="true"], dialog[open]')) return null;

  // Custom domains use the same publication template. A generic article at an unrelated
  // site's /p/ URL is insufficient evidence that the redirect reached a Substack story.
  const body = doc.querySelector('article.newsletter-post .body.markup, article .available-content .body.markup, .dt-post-body .body.markup') ||
    (substackHost && doc.querySelector('article .body.markup, article [itemprop="articleBody"], article'));
  if (!body) return null;
  for (let el = body; el; el = el.parentElement) {
    const style = styleOf(el);
    if (hidden(el, style) || obscured(el, style)) return null;
  }

  // Build fresh editorial markup. Page state, templates, alternate image sources and hidden
  // text never enter the snapshot. A clipped or concealed paragraph could be the paid ending.
  const ignored = 'script, template, noscript, style, textarea, iframe, svg, canvas, form, button, dialog, nav, aside, footer, header, ' +
    'h1, video, audio, [role="navigation"], .subscription-widget-wrap, .subscribe-widget, .button-wrapper, .image-link-expand, .byline-wrapper';
  const kept = new Set('p div h2 h3 h4 blockquote ul ol li strong em b i pre code br hr figure figcaption img'.split(' '));
  const output = doc.implementation.createHTMLDocument('');
  const content = output.createElement('article');
  const range = doc.createRange();
  function renderedText(node) {
    if (!node.nodeValue.trim()) return true;
    const style = styleOf(node.parentElement);
    const fill = style.webkitTextFillColor || style.color;
    if (fill === 'transparent' || /^rgba\([^)]*,\s*0\)$/.test(fill)) return false;
    range.selectNodeContents(node);
    return Array.from(range.getClientRects()).some(rect => rect.width > 0 && rect.height > 0 &&
      rect.right > 0 && rect.left < doc.documentElement.clientWidth && rect.bottom > -doc.defaultView.scrollY);
  }
  function copyChildren(from, to) {
    for (const node of from.childNodes) {
      if (node.nodeType === 3) {
        if (renderedText(node)) to.append(node.nodeValue);
        continue;
      }
      if (node.nodeType !== 1 || node.matches(ignored)) continue;
      const style = styleOf(node);
      if (hidden(node, style) || obscured(node, style)) {
        if (node.matches('p, blockquote, [itemprop="articleBody"]') || node.querySelector('p, blockquote')) return false;
        continue;
      }
      const tag = node.localName;
      if (!kept.has(tag)) {
        if (!copyChildren(node, to)) return false;
        continue;
      }
      const copy = output.createElement(tag);
      if (tag === 'img') {
        const src = node.currentSrc || node.src;
        if (!/^https?:\/\//i.test(src)) continue;
        copy.setAttribute('src', src);
        copy.setAttribute('alt', node.alt);
      }
      to.append(copy);
      if (!copyChildren(node, copy)) return false;
    }
    return true;
  }
  if (!copyChildren(body, content) || !content.textContent.trim()) return null;

  const article = body.closest('article') || body;
  const heading = article.querySelector('h1');
  output.title = (heading && visible(heading) && heading.innerText.trim()) || meta('og:title') || doc.title;
  for (const [name, value] of [
    ['author', meta('author')],
    ['og:site_name', meta('og:site_name') || doc.querySelector('link[rel~="alternate"][type="application/rss+xml"]')?.title],
    ['article:published_time', meta('article:published_time') || article.querySelector('time[datetime]')?.dateTime],
  ]) {
    if (!value) continue;
    const field = output.createElement('meta');
    field.name = name;
    field.content = value;
    output.head.append(field);
  }
  output.body.append(content);
  return {url: identity.href, html: output.documentElement.outerHTML};
}
