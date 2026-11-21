const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const {JSDOM} = require('jsdom');
const path = require('node:path');
const resource = path.join(__dirname,'../PaperboyCore/Sources/PaperboyCore/Resources');
function extract(html) {
  const dom = new JSDOM('<html></html>',{runScripts:'outside-only',url:'https://example.com/story'});
  try {
    const context = dom.getInternalVMContext();
    vm.runInContext(fs.readFileSync(path.join(resource,'Readability.js'),'utf8'),context);
    vm.runInContext(fs.readFileSync(path.join(resource,'ReaderMode.js'),'utf8'),context);
    return context.paperboyReaderHTML(html,'https://example.com/story');
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
