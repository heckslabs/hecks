/* ── Markdown renderer — outputs Tailwind-styled HTML ── */

function renderMd(src) {
  let html = '', inCode = false, codeLines = [];
  const lines = src.split('\n');
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (line.startsWith('```')) {
      if (inCode) {
        html += `<pre class="bg-bg-user p-3 rounded-md overflow-x-auto my-2.5"><code>${IDE.esc(codeLines.join('\n'))}</code></pre>`;
        inCode = false; codeLines = [];
      } else { inCode = true; }
      i++; continue;
    }
    if (inCode) { codeLines.push(line); i++; continue; }

    if (line.startsWith('### ')) html += `<h3 class="text-base mt-3.5 mb-2 text-fg">${mdInline(line.slice(4))}</h3>`;
    else if (line.startsWith('## ')) html += `<h2 class="text-xl mt-4 mb-2.5 text-fg">${mdInline(line.slice(3))}</h2>`;
    else if (line.startsWith('# ')) html += `<h1 class="text-2xl mt-5 mb-3 text-fg border-b border-border pb-2">${mdInline(line.slice(2))}</h1>`;
    else if (line.startsWith('> ')) html += `<blockquote class="border-l-[3px] border-border pl-3 text-fg-dim my-2">${mdInline(line.slice(2))}</blockquote>`;
    else if (/^[-*] /.test(line)) {
      html += '<ul class="pl-6 my-2">';
      while (i < lines.length && /^[-*] /.test(lines[i])) {
        html += `<li class="my-1">${mdInline(lines[i].slice(2))}</li>`; i++;
      }
      html += '</ul>'; continue;
    } else if (/^\d+\. /.test(line)) {
      html += '<ol class="pl-6 my-2">';
      while (i < lines.length && /^\d+\. /.test(lines[i])) {
        html += `<li class="my-1">${mdInline(lines[i].replace(/^\d+\.\s*/, ''))}</li>`; i++;
      }
      html += '</ol>'; continue;
    } else if (line.trim() === '') { /* skip */ }
    else html += `<p class="my-2">${mdInline(line)}</p>`;
    i++;
  }
  if (inCode) html += `<pre class="bg-bg-user p-3 rounded-md overflow-x-auto my-2.5"><code>${IDE.esc(codeLines.join('\n'))}</code></pre>`;
  return html;
}

function mdInline(s) {
  return IDE.esc(s)
    .replace(/`([^`]+)`/g, '<code class="bg-bg-user px-1.5 rounded font-mono text-[13px]">$1</code>')
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/\*([^*]+)\*/g, '<em>$1</em>')
    .replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" target="_blank" class="text-accent-blue">$1</a>');
}
