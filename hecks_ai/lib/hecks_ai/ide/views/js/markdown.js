/* ── Markdown renderer ── */

function renderMd(src) {
  let html = '', inCode = false, codeLines = [];
  const lines = src.split('\n');
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (line.startsWith('```')) {
      if (inCode) {
        html += `<pre><code>${IDE.esc(codeLines.join('\n'))}</code></pre>`;
        inCode = false; codeLines = [];
      } else {
        inCode = true;
      }
      i++; continue;
    }
    if (inCode) { codeLines.push(line); i++; continue; }

    if (line.startsWith('### ')) html += `<h3>${mdInline(line.slice(4))}</h3>`;
    else if (line.startsWith('## ')) html += `<h2>${mdInline(line.slice(3))}</h2>`;
    else if (line.startsWith('# ')) html += `<h1>${mdInline(line.slice(2))}</h1>`;
    else if (line.startsWith('> ')) html += `<blockquote>${mdInline(line.slice(2))}</blockquote>`;
    else if (/^[-*] /.test(line)) {
      html += '<ul>';
      while (i < lines.length && /^[-*] /.test(lines[i])) {
        html += `<li>${mdInline(lines[i].slice(2))}</li>`; i++;
      }
      html += '</ul>'; continue;
    } else if (/^\d+\. /.test(line)) {
      html += '<ol>';
      while (i < lines.length && /^\d+\. /.test(lines[i])) {
        html += `<li>${mdInline(lines[i].replace(/^\d+\.\s*/, ''))}</li>`; i++;
      }
      html += '</ol>'; continue;
    } else if (line.trim() === '') { /* skip */ }
    else html += `<p>${mdInline(line)}</p>`;
    i++;
  }
  if (inCode) html += `<pre><code>${IDE.esc(codeLines.join('\n'))}</code></pre>`;
  return html;
}

function mdInline(s) {
  return IDE.esc(s)
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/\*([^*]+)\*/g, '<em>$1</em>')
    .replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" target="_blank">$1</a>');
}
