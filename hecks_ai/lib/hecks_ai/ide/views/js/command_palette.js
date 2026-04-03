/* ── Ctrl+P command palette — commands + sessions from server ── */
IDE.register({
  onKeydown(e, ide) {
    if (e.ctrlKey && !e.metaKey && e.key === 'p') {
      e.preventDefault();
      ide.bus.emit('palette:open');
      return true;
    }
    return false;
  },

  handleSlash(text, ide) {
    if (text === '/palette' || text === '/commands') {
      ide.bus.emit('palette:open');
      return true;
    }
    return false;
  },

  init(ide) {
    const overlay = document.createElement('div');
    overlay.id = 'command-palette';
    overlay.style.cssText = 'display:none;position:fixed;inset:0;background:rgba(0,0,0,0.6);z-index:50;align-items:flex-start;justify-content:center;padding-top:20vh;';

    const box = document.createElement('div');
    box.style.cssText = 'background:#161b22;border:1px solid #30363d;border-radius:8px;width:440px;max-height:420px;overflow-y:auto;font-family:SF Mono,Fira Code,Menlo,monospace;font-size:13px;';

    const input = document.createElement('input');
    input.style.cssText = 'width:100%;background:#0d1117;border:none;border-bottom:1px solid #30363d;color:#c9d1d9;padding:12px 16px;font-family:SF Mono,Fira Code,Menlo,monospace;font-size:14px;outline:none;border-radius:8px 8px 0 0;';
    input.placeholder = 'Run a command...';

    const list = document.createElement('div');
    box.appendChild(input);
    box.appendChild(list);
    overlay.appendChild(box);
    document.body.appendChild(overlay);

    const staticCommands = [
      { name: 'Open Bluebook',  hint: 'Ctrl+O', type: 'command', action: () => ide.bus.emit('app-picker:open') },
      { name: 'Run Tests',      hint: '',        type: 'command', action: () => ide.bus.emit('test:run') },
      { name: 'Clear Chat',     hint: '',        type: 'command', action: () => { ide.el.msgs.innerHTML = ''; } },
      { name: 'Reset Session',  hint: '',        type: 'command', action: () => { ide.el.msgs.innerHTML = ''; ide.state.nextIndex = 0; } },
      { name: 'Toggle Sidebar', hint: '',        type: 'command', action: () => ide.bus.emit('sidebar:toggle') },
      { name: 'IDE Log',        hint: '',        type: 'command', action: () => ide.bus.emit('panel:show', 'ide-log') },
    ];

    let items = [];
    let selectedIdx = 0;

    const close = () => {
      overlay.style.display = 'none';
      ide.el.prompt.focus();
    };

    const connectSession = async (session) => {
      try {
        await fetch('/session/resume', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ session_id: session.id })
        });
        localStorage.setItem('hecks-ide-session', session.id);
        ide.bus.emit('session:connected', { session_id: session.id });
      } catch (e) {
        ide.addTurn('system', 'Failed to connect');
      }
    };

    const filtered = () => {
      const q = input.value.toLowerCase();
      return q ? items.filter(c => c.name.toLowerCase().includes(q)) : items;
    };

    const render = () => {
      const f = filtered();
      list.innerHTML = f.map((c, i) => {
        const sel = i === selectedIdx ? 'background:#1c2333;' : '';
        const hint = c.hint ? `<span style="color:#8b949e;font-size:10px">${c.hint}</span>` : '';
        const color = c.type === 'session' ? '#7ee787' : '#c9d1d9';
        const label = c.type === 'session'
          ? `<span style="color:#7ee787;font-size:10px">${c.active ? 'active' : 'session'}</span>`
          : hint;
        return `<div data-idx="${i}" style="padding:8px 16px;cursor:pointer;display:flex;justify-content:space-between;align-items:center;${sel}"><span style="color:${color}">${IDE.esc(c.name)}</span>${label}</div>`;
      }).join('') || '<div style="padding:12px 16px;color:#8b949e">No matches</div>';
      const selEl = list.querySelector(`[data-idx="${selectedIdx}"]`);
      if (selEl) selEl.scrollIntoView({ block: 'nearest' });
    };

    ide.bus.on('palette:open', async () => {
      overlay.style.display = 'flex';
      input.value = '';
      selectedIdx = 0;
      items = [...staticCommands];
      render();
      input.focus();
      try {
        const r = await fetch('/sessions');
        const d = await r.json();
        const currentId = localStorage.getItem('hecks-ide-session');
        const sessions = (d.sessions || []).map(s => ({
          name: `${s.preview || s.id.slice(0,8)}  (${s.age})`,
          hint: s.id.slice(0, 8),
          type: 'session',
          active: s.id === currentId,
          action: () => connectSession(s)
        }));
        items = [...sessions, ...staticCommands];
        render();
      } catch (e) {}
    });

    overlay.addEventListener('click', e => { if (e.target === overlay) close(); });

    input.addEventListener('keydown', e => {
      if (e.key === 'Escape') { close(); return; }
      const f = filtered();
      if (e.key === 'ArrowDown') { e.preventDefault(); selectedIdx = Math.min(selectedIdx + 1, f.length - 1); render(); return; }
      if (e.key === 'ArrowUp') { e.preventDefault(); selectedIdx = Math.max(selectedIdx - 1, 0); render(); return; }
      if (e.key === 'Enter') {
        if (f[selectedIdx]) { close(); f[selectedIdx].action(); }
        return;
      }
    });

    input.addEventListener('input', () => { selectedIdx = 0; render(); });
  }
});
