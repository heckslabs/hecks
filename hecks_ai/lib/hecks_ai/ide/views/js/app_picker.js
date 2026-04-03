/* ── Ctrl+O application picker — domain / hecksagon chooser ── */
IDE.register({
  onKeydown(e, ide) {
    if (e.ctrlKey && !e.metaKey && e.key === 'o') {
      e.preventDefault();
      ide.bus.emit('app-picker:open');
      return true;
    }
    return false;
  },

  init(ide) {
    const overlay = document.createElement('div');
    overlay.id = 'app-picker';
    overlay.style.cssText = 'display:none;position:fixed;inset:0;background:rgba(0,0,0,0.6);z-index:50;align-items:flex-start;justify-content:center;padding-top:20vh;';

    const box = document.createElement('div');
    box.style.cssText = 'background:#161b22;border:1px solid #30363d;border-radius:8px;width:700px;max-height:400px;overflow-y:auto;font-family:SF Mono,Fira Code,Menlo,monospace;font-size:13px;';

    const input = document.createElement('input');
    input.style.cssText = 'width:100%;background:#0d1117;border:none;border-bottom:1px solid #30363d;color:#c9d1d9;padding:12px 16px;font-family:SF Mono,Fira Code,Menlo,monospace;font-size:14px;outline:none;border-radius:8px 8px 0 0;';
    input.placeholder = 'Open app...';

    const list = document.createElement('div');
    box.appendChild(input);
    box.appendChild(list);
    overlay.appendChild(box);
    document.body.appendChild(overlay);

    let items = [];
    let selectedIdx = 0;

    const close = () => { overlay.style.display = 'none'; ide.el.prompt.focus(); };

    const filtered = () => {
      const q = input.value.toLowerCase();
      if (!q) return items;
      const matchedApps = new Set(items.filter(it => it.type !== 'app' && it.appName.toLowerCase().includes(q)).map(it => it.appName));
      return items.filter(it => matchedApps.has(it.type === 'app' ? it.name : it.appName));
    };

    const render = () => {
      const f = filtered();
      list.innerHTML = f.map((it, i) => {
        if (it.type === 'app') {
          return `<div style="padding:8px 16px 2px;${i > 0 ? 'border-top:1px solid #30363d;margin-top:2px;' : ''}">` +
            `<span style="color:#7ee787;font-size:10px;text-transform:uppercase;letter-spacing:0.5px">${IDE.esc(it.name)}</span></div>`;
        }
        const sel = i === selectedIdx ? 'background:#1c2333;' : '';
        const color = it.type === 'hecksagon' ? '#d29922' : '#58a6ff';
        const label = it.type === 'hecksagon' ? 'Hecksagon' : 'Domain';
        const onclick = it.type === 'hecksagon'
          ? `openHecksagon('${it.path}')`
          : `openWorkshop('${it.path}','${IDE.esc(it.appName)}')`;
        return `<div data-idx="${i}" style="padding:4px 16px 4px 32px;cursor:pointer;display:flex;justify-content:space-between;${sel}" ` +
          `onclick="document.getElementById('app-picker').style.display='none';${onclick}">` +
          `<span style="color:${color}">${label}</span>` +
          `<span style="color:#8b949e;font-size:10px">${IDE.esc(it.path)}</span></div>`;
      }).join('') || '<div style="padding:12px 16px;color:#8b949e">No matches</div>';

      const selEl = list.querySelector(`[data-idx="${selectedIdx}"]`);
      if (selEl) selEl.scrollIntoView({ block: 'nearest' });
    };

    ide.bus.on('app-picker:open', async () => {
      overlay.style.display = 'flex';
      input.value = '';
      selectedIdx = 0;
      try {
        const r = await fetch('/bluebooks');
        const d = await r.json();
        items = [];
        (d.apps || []).forEach(a => {
          items.push({ type: 'app', name: a.name, appName: a.name, path: '' });
          items.push({ type: 'bluebook', name: 'Domain', appName: a.name, path: a.path });
          if (a.hecksagon) {
            items.push({ type: 'hecksagon', name: 'Hecksagon', appName: a.name, path: a.hecksagon });
          }
        });
      } catch (e) { items = []; }
      selectedIdx = items.findIndex(it => it.type !== 'app');
      if (selectedIdx < 0) selectedIdx = 0;
      render();
      input.focus();
    });

    overlay.addEventListener('click', e => { if (e.target === overlay) close(); });

    const skipHeaders = (idx, dir) => {
      const f = filtered();
      while (idx >= 0 && idx < f.length && f[idx].type === 'app') idx += dir;
      return Math.max(0, Math.min(idx, f.length - 1));
    };

    input.addEventListener('keydown', e => {
      if (e.key === 'Escape') { close(); return; }
      if (e.key === 'ArrowDown') { e.preventDefault(); selectedIdx = skipHeaders(selectedIdx + 1, 1); render(); return; }
      if (e.key === 'ArrowUp') { e.preventDefault(); selectedIdx = skipHeaders(selectedIdx - 1, -1); render(); return; }
      if (e.key === 'Enter') {
        const f = filtered();
        const it = f[selectedIdx];
        if (it && it.type !== 'app') {
          close();
          if (it.type === 'hecksagon') openHecksagon(it.path);
          else openWorkshop(it.path, it.appName);
        }
        return;
      }
    });

    input.addEventListener('input', () => {
      selectedIdx = 0;
      const f = filtered();
      if (f[0]?.type === 'app') selectedIdx = skipHeaders(0, 1);
      render();
    });
  }
});
