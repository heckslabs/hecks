/* ── File tab viewer — open files as tabs ── */

function toggleBookAggs(id) {
  IDE.bus.emit('bluebook:toggle', id);
}

IDE.register({
  init(ide) {
    ide.bus.on('bluebook:toggle', (id) => {
      const el = document.getElementById('aggs-' + id);
      const chev = document.getElementById('chev-' + id);
      if (el) el.classList.toggle('collapsed');
      if (chev) chev.classList.toggle('open');
    });

    ide.bus.on('file:open', () => {}); // already emitted by openFile
  }
});

async function openFile(path, opts) {
  const isDoc = opts?.doc || path.startsWith('docs/');
  const id = isDoc ? 'docs' : 'file-' + path.replace(/[^a-zA-Z0-9]/g, '_');

  if (isDoc && IDE.state.openTabs[id]) {
    await loadFileInto(IDE.state.openTabs[id].content, path);
    IDE.state.openTabs[id].tab.querySelector('.tab-label').textContent = path.split('/').pop();
    IDE.state.openTabs[id].path = path;
    IDE.switchTab(id);
    return;
  }
  if (IDE.state.openTabs[id]) { IDE.switchTab(id); return; }

  const content = IDE.createTab(id, path.split('/').pop());
  IDE.state.openTabs[id].path = path;
  await loadFileInto(content, path);
  IDE.switchTab(id);
  IDE.bus.emit('file:open', path);
}

async function loadFileInto(el, path) {
  try {
    const r = await fetch('/file/' + encodeURIComponent(path));
    const text = await r.text();
    if (path.endsWith('.md')) {
      el.innerHTML = `<div class="md-view"><div class="file-view-path">${IDE.esc(path)}</div>${renderMd(text)}</div>`;
    } else {
      el.innerHTML = `<div class="file-view"><div class="file-view-path">${IDE.esc(path)}</div><pre>${IDE.esc(text)}</pre></div>`;
    }
  } catch (e) {
    el.innerHTML = '<div class="file-view">Failed to load file.</div>';
  }
}
