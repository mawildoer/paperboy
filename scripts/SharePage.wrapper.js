// Safari gives us the signed-in rendered page, including accessible canvas/SVG figures.
var SharePage = function () {};
SharePage.prototype = {
  run: function (args) {
    const url = document.URL, title = document.title;
    const economist = paperboyIsEconomist(url);
    const captures = [];
    let figureCount = 0;
    const captureFigure = (original, copy) => {
      try {
        if (figureCount >= 6 || !['canvas','svg'].includes(original.localName)) return;
        const rect = original.getBoundingClientRect();
        if (rect.width < 120 || rect.height < 70) return;
        figureCount++;
        const replace = data => {
          if (!data || data.length > 350000) return;
          const img = document.createElement('img');
          img.src = data;
          img.alt = original.getAttribute('aria-label') || original.querySelector('title')?.textContent || 'Chart';
          copy.replaceWith(img);
        };
        if (original.tagName.toLowerCase() === 'canvas') {
          replace(original.toDataURL('image/png'));
        } else {
          const svg = copy;
          svg.setAttribute('xmlns','http://www.w3.org/2000/svg');
          svg.setAttribute('width',rect.width); svg.setAttribute('height',rect.height);
          const originals = [original, ...original.querySelectorAll('*')];
          const copies = [svg, ...svg.querySelectorAll('*')];
          originals.forEach((node,index) => {
            const target = copies[index]; if (!target) return;
            const computed = getComputedStyle(node);
            for (const key of ['fill','stroke','stroke-width','font-family','font-size','font-weight','text-anchor']) target.style.setProperty(key, computed.getPropertyValue(key));
          });
          svg.querySelectorAll('script,foreignObject').forEach(n => n.remove());
          // Serialize after the visibility pass has also visited and pruned SVG descendants.
          const task = Promise.resolve().then(() => new Promise(resolve => {
            const blob = URL.createObjectURL(new Blob([new XMLSerializer().serializeToString(svg)], {type:'image/svg+xml'}));
            const image = new Image();
            image.onload = () => {
              try {
                const scale = Math.min(2,1056/rect.width,1584/rect.height);
                const canvas = document.createElement('canvas');
                canvas.width = Math.max(1,Math.round(rect.width*scale)); canvas.height = Math.max(1,Math.round(rect.height*scale));
                const context = canvas.getContext('2d');
                context.fillStyle='white'; context.fillRect(0,0,canvas.width,canvas.height);
                context.drawImage(image,0,0,canvas.width,canvas.height); replace(canvas.toDataURL('image/png'));
              } catch (_) {}
              URL.revokeObjectURL(blob); resolve();
            };
            image.onerror = () => { URL.revokeObjectURL(blob); resolve(); };
            image.src = blob;
          }));
          captures.push(task);
        }
      } catch (_) {} // Cross-origin canvas and unsupported figures still retain surrounding text.
    };
    let clone;
    try { clone = paperboyRenderedClone(document, captureFigure); } catch (_) {}
    let finished = false;
    const finish = () => {
      if (finished) return; finished = true;
      const html = clone?.documentElement?.outerHTML;
      let result = null;
      try { if (html) result = paperboyReaderHTML(html, url); } catch (_) {}
      const error = result?.error || (economist && !result?.html ? economistAccessError : null);
      if (error) {
        // The shared inbox persists only url/title/html. Never persist the original wall or teaser.
        const record = document.implementation.createHTMLDocument('');
        const meta = record.createElement('meta');
        meta.name = 'paperboy-access-error'; meta.content = error; record.head.append(meta);
        const origin = record.createElement('meta');
        origin.name = 'paperboy-reader-origin'; origin.content = url; record.head.append(origin);
        args.completionFunction({url, title, html:record.documentElement.outerHTML, error, readerExtracted:false});
      } else {
        args.completionFunction({url, title:result?.title || title,
          html:result?.html || html || document.documentElement.outerHTML, readerExtracted:!!result?.html});
      }
    };
    Promise.allSettled(captures).then(finish);
    setTimeout(finish,1500);
  },
  finalize: function () {},
};
var ExtensionPreprocessingJS = new SharePage();
