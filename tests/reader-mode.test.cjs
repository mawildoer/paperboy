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
