/* ── Cmd+O application picker ── */
IDE.register({
  onKeydown(e, ide) {
    if ((e.metaKey || e.ctrlKey) && e.key === 'o') {
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
    box.style.cssText = 'background:var(--bg-msg);border:1px solid var(--border);border-radius:8px;width:400px;max-height:400px;overflow-y:auto;font-family:var(--mono);font-size:13px;';

    const input = document.createElement('input');
    input.style.cssText = 'width:100%;background:var(--bg);border:none;border-bottom:1px solid var(--border);color:var(--fg);padding:12px 16px;font-family:var(--mono);font-size:14px;outline:none;border-radius:8px 8px 0 0;';
    input.placeholder = 'Open application...';

    const list = document.createElement('div');
    box.appendChild(input);
    box.appendChild(list);
    overlay.appendChild(box);
    document.body.appendChild(overlay);

    let apps = [];
    let selectedIdx = 0;

    const close = () => {
      overlay.style.display = 'none';
      ide.el.prompt.focus();
    };

    const filtered = () => {
      const q = input.value.toLowerCase();
      return q ? apps.filter(a => a.name.toLowerCase().includes(q)) : apps;
    };

    const pick = (item) => {
      if (item.action === 'hecksagon') openHecksagon(item.path);
      else openWorkshop(item.path, item.name);
    };

    const render = () => {
      const f = filtered();
      list.innerHTML = f.map((a, i) => {
        const sel = i === selectedIdx ? 'background:var(--bg-user);' : '';
        const color = a.type === 'hecksagon' ? 'var(--yellow)' : 'var(--blue)';
        const label = a.type === 'hecksagon' ? 'Hecksagon' : 'Bluebook';
        return `<div style="padding:8px 16px;cursor:pointer;display:flex;justify-content:space-between;${sel}" onclick="document.getElementById('app-picker').style.display='none';${a.action==='hecksagon'?"openHecksagon('"+a.path+"')":"openWorkshop('"+a.path+"','"+IDE.esc(a.name)+"')"}"><span>${IDE.esc(a.name)}</span><span style="color:${color};font-size:10px">${label}</span></div>`;
      }).join('') || '<div style="padding:12px 16px;color:var(--fg-dim)">No matches</div>';
    };

    ide.bus.on('app-picker:open', async () => {
      overlay.style.display = 'flex';
      input.value = '';
      selectedIdx = 0;
      try {
        const r = await fetch('/bluebooks');
        const d = await r.json();
        apps = [];
        (d.apps || []).forEach(a => {
          apps.push({ name: a.name, type: 'bluebook', path: a.path, action: 'workshop' });
          if (a.hecksagon) apps.push({ name: a.name, type: 'hecksagon', path: a.hecksagon, action: 'hecksagon' });
        });
      } catch (e) { apps = []; }
      render();
      input.focus();
    });

    overlay.addEventListener('click', e => { if (e.target === overlay) close(); });

    input.addEventListener('keydown', e => {
      if (e.key === 'Escape') { close(); return; }
      if (e.key === 'ArrowDown') { e.preventDefault(); selectedIdx = Math.min(selectedIdx + 1, filtered().length - 1); render(); return; }
      if (e.key === 'ArrowUp') { e.preventDefault(); selectedIdx = Math.max(selectedIdx - 1, 0); render(); return; }
      if (e.key === 'Enter') {
        const f = filtered();
        if (f[selectedIdx]) { close(); pick(f[selectedIdx]); }
        return;
      }
    });

    input.addEventListener('input', () => { selectedIdx = 0; render(); });
  }
});
