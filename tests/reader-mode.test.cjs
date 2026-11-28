const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const {JSDOM} = require('jsdom');
const path = require('node:path');
const resource = path.join(__dirname,'../PaperboyCore/Sources/PaperboyCore/Resources');
function extract(html, url = "https://example.com/story") {
  const dom = new JSDOM('<html></html>',{runScripts:'outside-only',url:'https://example.com/story'});
  try {
    const context = dom.getInternalVMContext();
    vm.runInContext(fs.readFileSync(path.join(resource,'Readability.js'),'utf8'),context);
    vm.runInContext(fs.readFileSync(path.join(resource,'ReaderMode.js'),'utf8'),context);
    return context.paperboyReaderHTML(html,url);
  } finally {dom.window.close();}
}
test('article extraction keeps paragraphs, a lazy chart, caption and metadata but drops ads and recommendations',()=>{
  const p = '<p>The research team measured household output over five quarters. The plotted blue and orange lines show the effect of the intervention. These measurements are reported with confidence intervals and clear source attribution, to make the comparison reproducible.</p>';
  const result = extract(`<html><head><title>A rigorous study</title><meta name="author" content="Ada Writer"><meta property="og:site_name" content="Research Journal"></head><body><nav>Navigation links</nav><main><article><h1>A rigorous study</h1>${p.repeat(5)}<figure><img src="data:image/gif;base64,R0" data-src="/chart.png" alt="Output plot"><figcaption>Source: measured data</figcaption></figure><section class="read-next">Unrelated next article</section><div class="advertisement">Buy things now</div><aside>Recommended posts</aside></article></main><footer>Cookie policy links</footer></body></html>`);
  assert.ok(result);
  assert.match(result.html,/confidence intervals/);
  assert.match(result.html,/https:\/\/example.com\/chart.png/);
  assert.match(result.html,/Source: measured data/);
  for(const text of ['Unrelated next article','Buy things now','Recommended posts','Navigation links','Cookie policy links']) assert.ok(!result.html.includes(text),text);
  assert.equal(result.author,'Ada Writer');
  assert.equal(result.source,'Research Journal');
});
test('does not execute publisher JavaScript',()=>{
  const prose='<p>This is an article with substantial original prose about public transport, household mobility and urban design. Its evidence describes a comparison of cities and the costs faced by commuters.</p>'.repeat(5);
  assert.ok(extract(`<html><head><title>Transport study</title></head><body><article>${prose}</article><script>throw new Error('publisher script executed');</script></body></html>`));
});
test('refuses navigation-only pages',()=>{
  assert.equal(extract('<html><body><nav><a href="/one">One</a><a href="/two">Two</a></nav></body></html>'),null);
});
test('Safari preprocessing bundle is reproducible',()=>{
  const expected = ['Readability.js','ReaderMode.js'].map(n=>fs.readFileSync(path.join(resource,n),'utf8')).join('') + fs.readFileSync(path.join(__dirname,'../scripts/SharePage.wrapper.js'),'utf8');
  assert.equal(fs.readFileSync(path.join(__dirname,'../Paperboy/ShareExtension/SharePage.js'),'utf8'),expected);
});

test('Medium member story preserves text, chart, author and publication time without recommendations',()=>{
  const text='<p>This member story explains the experiment, its measurements and the observed trend in detail. Each chart plots a clear comparison over time, with confidence intervals and sources included so readers can assess the evidence.</p>'.repeat(6);
  const result=extract(`<html><head><title>A member story</title><meta name="author" content="Ada Writer"><meta property="og:site_name" content="Medium"><meta property="article:published_time" content="2026-11-25T17:42:30Z"></head><body><article><h1>A member story</h1><div>Member-only story</div>${text}<figure><img src="https://miro.medium.com/chart.png" alt="Output chart"><figcaption>Figure 1: measured output</figcaption></figure></article><aside>Recommended from Medium</aside></body></html>`, 'https://medium.com/@ada/story-123456abcdef');
  assert.ok(result?.html);
  assert.match(result.html,/measured output/);
  assert.match(result.html,/miro.medium.com/);
  assert.ok(!result.html.includes('Recommended from Medium'));
  assert.equal(result.author,'Ada Writer');
  assert.equal(result.date,'2026-11-25T17:42:30Z');
});
test('Medium refuses a long paywall preview, including on custom domains',()=>{
  const preview='<p>A substantial free preview can look like a complete article to a reader-mode extractor. This paragraph explains a few ideas, but the rest of this member story is still unavailable.</p>'.repeat(8);
  for (const url of ['https://medium.com/@ada/story-123456abcdef','https://writing.example/story-123456abcdef']) {
    const result=extract(`<html><head><title>Locked story</title><meta property="al:ios:app_name" content="Medium"></head><body><article>${preview}<div data-testid="paywall">Become a member to read this story</div></article></body></html>`, url);
    assert.equal(result?.error,'medium-access-required');
    assert.equal(result?.html,undefined);
  }
});

test('hidden Medium paywall templates do not hide a readable member story',()=>{
  const prose='<p>This full article discusses a detailed research result with useful observations, reproducible methods, measurements, and clearly stated conclusions for readers to evaluate.</p>'.repeat(7);
  const result=extract(`<html><head><title>Accessible member story</title></head><body><article>${prose}</article><div hidden data-testid="paywall">Become a member to read</div></body></html>`, 'https://medium.com/@ada/story-123456abcdef');
  assert.ok(result?.html);
});

test('strips unclassed ad labels, accessibility controls and semantic ad slots across publishers', () => {
  const lede = 'As November comes to a close, friends ask what to do with their leftovers.';
  const editorial = 'The court quoted the words “skip advertisement” in its opinion about advertising.';
  const html = `<title>Leftovers</title><article><h1>Leftovers</h1>
    <div><p>Advertisement</p><a href="#after-ad"><span>SKIP ADVERTISEMENT</span></a></div>
    <p>${lede}</p><div aria-label="Advertisement"><img src="/ad.png">Offer ends soon</div>
    <div data-ad-slot="inline"><p>Buy this now</p></div>
    <p>${editorial.repeat(4)}</p><figure><img src="/chart.png"><figcaption>Advertising revenue by quarter</figcaption></figure></article>`;
  for (const url of ['https://www.nytimes.com/story', 'https://example.org/story']) {
    const result = extract(html, url);
    const content = new JSDOM(result.html).window.document.querySelector('article');
    assert.ok(content.textContent.trim().startsWith(lede));
    assert.ok(content.textContent.includes(editorial));
    assert.ok(content.textContent.includes('Advertising revenue by quarter'));
    assert.ok(!content.textContent.includes('Offer ends soon'));
    assert.ok(!content.textContent.includes('Buy this now'));
    assert.equal(content.querySelectorAll('img').length, 1);
  }
});

const economistURL = 'https://www.economist.com/finance-and-economics/2026/11/20/a-city-counts-its-buses';
const accessRequired = 'economist-access-required';
const economistHead = `<head><title>A city counts its buses</title><meta name="author" content="Ada Writer">
  <meta property="og:site_name" content="The Economist"><meta property="article:published_time" content="2026-11-20T12:00:00Z"></head>`;
const reporting = `<p>The new timetable answered a question passengers had asked for years. Each morning a team counted the buses that actually reached the station before the first train departed.</p>
  <p>Early returns favoured the smaller routes, where drivers could wait for a late connection. On the main road a short delay at the bridge would ripple through the whole timetable.</p>
  <p>In the final count, the busiest route had gained the most. The city published its observations alongside the timetable so passengers could compare the two for themselves.</p>`;
const paidPayload = 'UNDISCLOSED_CONTINUATION';
const fullEconomist = `${economistHead}<body><nav>Log in | Subscribe</nav>
  <main><article><header><h1>A city counts its buses</h1></header>${reporting}
  <figure><img src="/images/bus.png" alt="Bus frequency"><figcaption>Morning departures by route</figcaption></figure>
  <footer><h2>Subscribe to The Economist</h2><p>Get unlimited access to our journalism.</p>
    <a href="/subscribe">Subscribe now</a> Already a subscriber? Log in</footer></article></main>
  <div hidden data-testid="paywall">Subscribe to continue reading</div></body>`;
const wallEconomist = `${economistHead}<body><main><article><h1>A city counts its buses</h1>${reporting.repeat(3)}</article>
  <aside data-test-id="paywall"><h2>Subscribe to continue reading</h2><button>View subscription options</button></aside>
  <div hidden><p>${paidPayload}</p></div><script type="application/ld+json">{"articleBody":"${paidPayload}"}</script>
  </main></body>`;

// Exercise the shipped Safari bundle and the exact JS entry point called by WKWebView.
async function rendered(html, method, url = economistURL) {
  const dom = new JSDOM(html, {url, runScripts:'outside-only'});
  try {
    const context = dom.getInternalVMContext();
    vm.runInContext(fs.readFileSync(path.join(__dirname, '../Paperboy/ShareExtension/SharePage.js'), 'utf8'), context);
    if (method === 'snapshot') return context.paperboyEconomistSnapshot(context.document);
    return await new Promise(resolve => context.ExtensionPreprocessingJS.run({completionFunction: resolve}));
  } finally { dom.window.close(); }
}

function assertFullEconomist(result) {
  assert.equal(result?.error, undefined);
  assert.ok(result?.html);
  assert.match(result.html, /In the final count/);
  assert.match(result.html, /Morning departures by route/);
  assert.match(result.html, /https:\/\/www\.economist\.com\/images\/bus\.png/);
  assert.doesNotMatch(result.html, /subscription options|unlimited access|subscribe now|UNDISCLOSED_CONTINUATION/i);
  assert.equal(result.title, 'A city counts its buses');
}

test('Economist full article keeps the conclusion, chart and metadata with a footer subscription offer', () => {
  const result = extract(fullEconomist, economistURL);
  assertFullEconomist(result);
  assert.equal(result.author, 'Ada Writer');
  assert.equal(result.source, 'The Economist');
  assert.equal(result.date, '2026-11-20T12:00:00Z');
});

test('Economist refuses a substantial preview with a visible wall outside the article', () => {
  const result = extract(wallEconomist, economistURL);
  assert.equal(result?.error, accessRequired);
  assert.equal(result?.html, undefined);
});

test('Economist checks textual gates, teaser-only markup, challenges and login redirects', async () => {
  for (const [markup, url] of [
    [`<article>${reporting}</article><form><strong>Subscribe</strong> to read the full article</form>`, economistURL],
    [`<article>${reporting}</article><section><h2>To continue reading this article, please subscribe</h2></section>`, economistURL],
    [`<article>${reporting}</article><div class="tp-modal"><iframe title="Subscribe"></iframe></div>`, economistURL],
    [`<article><header>${reporting}</header></article><aside>${reporting}</aside>`, economistURL],
    [`<article><div class="article__teaser">${reporting}</div></article>`, economistURL],
    [`<article>${reporting}<div hidden itemprop="articleBody"><p>${paidPayload}</p></div></article>`, economistURL],
    [`<h1>Verify you are human</h1><article>${reporting}</article>`, economistURL],
    [`<title>Just a moment...</title><article>${reporting}</article>`, economistURL],
    [fullEconomist, 'https://myaccount.economist.com/login'],
    [fullEconomist, 'https://www.economist.com/sign-in?next=/article'],
  ]) {
    assert.equal(extract(markup, url)?.error, accessRequired, url);
  }
  const onForeignLogin = await rendered(fullEconomist, 'snapshot', 'https://economist.com.example/login');
  assert.equal(onForeignLogin.error, accessRequired);
  assert.equal(onForeignLogin.html, undefined);
  assert.ok(extract(wallEconomist, 'https://economist.com.example/story')?.html);
});

test('detached Economist extraction excludes hidden and inert payloads and refuses unresolved stylesheets', () => {
  const payloads = ['hidden', 'inert', 'aria-hidden="true"', 'style="display: none !important"',
    'style="visibility: hidden"', 'style="opacity: 0"', 'style="content-visibility: hidden"'];
  const concealed = payloads.map(attributes => `<div ${attributes}><p>${paidPayload}</p></div>`).join('');
  const html = fullEconomist.replace('</article>', `${concealed}<template>${paidPayload}</template>
    <noscript><p>${paidPayload}</p></noscript><details><p>${paidPayload}</p></details>
    <div data-hidden-state="${paidPayload}"></div><img src="/placeholder.png" data-src="/${paidPayload}.png">
    <script type="application/json">{"articleBody":"${paidPayload}"}</script></article>`);
  assertFullEconomist(extract(html, economistURL));
  for (const stylesheet of ['<style>.extra {display:none}</style>', '<link rel="stylesheet" href="/site.css">']) {
    const result = extract(html.replace('</head>', stylesheet + '</head>'), economistURL);
    assert.equal(result?.error, accessRequired);
    assert.equal(result?.html, undefined);
  }
  const clipped = fullEconomist.replace('</article>', `<div style="max-height:3em; overflow:hidden"><p>${paidPayload}</p></div></article>`);
  assert.equal(extract(clipped, economistURL)?.error, accessRequired);
});

test('Safari and WKWebView only snapshot visible Economist text and keep it on the second pass', async () => {
  const styled = fullEconomist
    .replace('</head>', '<style>.unavailable { display:none }</style></head>')
    .replace('</article>', `<div class="unavailable"><p>${paidPayload}</p></div></article>`)
    .replace('<div hidden data-testid', '<div class="unavailable" data-testid');
  for (const method of ['safari', 'snapshot']) {
    const result = await rendered(styled, method);
    assertFullEconomist(result);
    if (method === 'safari') {
      assert.equal(result.url, economistURL);
      assert.equal(result.readerExtracted, true);
    }
    const again = extract(result.html, economistURL);
    assertFullEconomist(again);
    assert.equal(again.author, 'Ada Writer');
    assert.equal(again.date, '2026-11-20T12:00:00Z');
    assert.match(again.html, /paperboy-reader-origin/);
  }
});

test('Safari persists a content-free access error through the inbox HTML-only handoff', async () => {
  const snapshot = await rendered(wallEconomist, 'snapshot');
  assert.equal(snapshot.error, accessRequired);
  assert.equal(snapshot.html, undefined);
  const shared = await rendered(wallEconomist, 'safari');
  assert.equal(shared.url, economistURL);
  assert.equal(shared.readerExtracted, false);
  assert.equal(shared.error, accessRequired);
  assert.ok(!shared.html.includes(paidPayload));
  assert.doesNotMatch(shared.html, /new timetable|View subscription options/);
  const record = new JSDOM(shared.html);
  try {
    assert.equal(record.window.document.body.textContent, '');
    assert.equal(record.window.document.querySelector('meta[name="paperboy-reader-origin"]').content, economistURL);
  } finally { record.window.close(); }
  // The extension drops arbitrary JS result fields when it writes {url, title, html}.
  for (const url of [shared.url, 'https://example.org/share']) {
    const again = extract(shared.html, url);
    assert.equal(again?.error, accessRequired);
    assert.equal(again?.html, undefined);
  }
});

test('signed-in publication snapshots use visible article text and reject an access screen', () => {
  for (const [publisher, url] of [['nyt', 'https://www.nytimes.com/2026/11/27/business/story.html'],
                                  ['medium', 'https://medium.com/@writer/story-0123456789ab']]) {
    const snapshot = (wall) => {
      const page = new JSDOM(`<title>City buses</title><article>${reporting}
        <p style="display:none">A hidden payload</p></article>${wall}`, {url, runScripts:'outside-only'});
      try {
        vm.runInContext(fs.readFileSync(path.join(resource, 'ReaderMode.js'), 'utf8'), page.getInternalVMContext());
        return page.window.paperboySharedStorySnapshot(page.window.document, publisher);
      } finally { page.window.close(); }
    };
    assert.match(snapshot(''), /busiest route/);
    assert.doesNotMatch(snapshot(''), /A hidden payload/);
    assert.equal(snapshot('<div data-testid="gateway-content">Subscribe to continue reading</div>'), null);
  }
});

test('Safari passes platform metadata for routing custom publication domains', async () => {
  const page = '<head><meta property="al:ios:app_name" content="Medium"></head><article>' + reporting + '</article>';
  const shared = await rendered(page, 'safari', 'https://independent.example/piece-0123456789ab');
  assert.match(shared.publisherMetadata, /al:ios:app_name/);
  assert.doesNotMatch(shared.publisherMetadata, /busiest route/);
});
