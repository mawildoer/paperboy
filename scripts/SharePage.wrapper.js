// Safari gives us the signed-in rendered page, including accessible canvas/SVG figures.
var SharePage = function () {};
SharePage.prototype = {
  run: function (args) {
    const clone = document.documentElement.cloneNode(true);
    const originalNodes = Array.from(document.documentElement.querySelectorAll('*'));
    const clonedNodes = Array.from(clone.querySelectorAll('*'));
    const captures = [];
    let figureCount = 0;
    for (let i = 0; i < originalNodes.length && i < 30000; i++) {
      const original = originalNodes[i], copy = clonedNodes[i];
      if (!copy) continue;
      try {
        const style = getComputedStyle(original);
        if (style.display === 'none' || style.visibility === 'hidden') { copy.remove(); continue; }
        if (original.tagName.toLowerCase() === 'img' && original.currentSrc) copy.setAttribute('src', original.currentSrc);
        if (figureCount >= 6 || !['canvas','svg'].includes(original.tagName.toLowerCase())) continue;
        const rect = original.getBoundingClientRect();
        if (rect.width < 120 || rect.height < 70) continue;
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
          const task = new Promise(resolve => {
            const svg = original.cloneNode(true);
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
          });
          captures.push(task);
        }
      } catch (_) {} // Cross-origin canvas and unsupported figures still retain surrounding text.
    }
    let finished = false;
    const finish = () => {
      if (finished) return; finished = true;
      let html = clone.outerHTML, result = null;
      try { result = paperboyReaderHTML(html, document.URL); } catch (_) {}
      args.completionFunction({url:document.URL,title:result?.title || document.title,
        html:result?.html || html,readerExtracted:!!result});
    };
    Promise.allSettled(captures).then(finish);
    setTimeout(finish,1500);
  },
  finalize: function () {},
};
var ExtensionPreprocessingJS = new SharePage();
