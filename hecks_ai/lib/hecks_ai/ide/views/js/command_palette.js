/* ── Cmd+P command palette ── */
IDE.register({
  onKeydown(e, ide) {
    if ((e.metaKey || e.ctrlKey) && e.key === 'j') {
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

    const commands = [
      { name: 'Sessions',       hint: '',       action: () => ide.bus.emit('session-picker:open') },
      { name: 'Open Bluebook',  hint: 'Cmd+O', action: () => ide.bus.emit('app-picker:open') },
      { name: 'Run Tests',      hint: '',       action: () => ide.bus.emit('test:run') },
      { name: 'Clear Chat',     hint: '',       action: () => { ide.el.msgs.innerHTML = ''; } },
      { name: 'Reset Session',  hint: '',       action: () => { ide.el.msgs.innerHTML = ''; ide.state.nextIndex = 0; } },
      { name: 'Toggle Sidebar', hint: '',       action: () => ide.bus.emit('sidebar:toggle') },
      { name: 'IDE Log',        hint: '',       action: () => ide.bus.emit('panel:show', 'ide-log') },
      { name: 'Screenshot',     hint: '',       action: () => ide.bus.emit('screenshot:capture') },
    ];

    let selectedIdx = 0;

    const close = () => {
      overlay.style.display = 'none';
      ide.el.prompt.focus();
    };

    const filtered = () => {
      const q = input.value.toLowerCase();
      return q ? commands.filter(c => c.name.toLowerCase().includes(q)) : commands;
    };

    const render = () => {
      const f = filtered();
      list.innerHTML = f.map((c, i) => {
        const sel = i === selectedIdx ? 'background:#1c2333;' : '';
        const hint = c.hint ? `<span style="color:#8b949e;font-size:10px">${c.hint}</span>` : '';
        return `<div data-idx="${i}" style="padding:8px 16px;cursor:pointer;display:flex;justify-content:space-between;align-items:center;${sel}"><span style="color:#c9d1d9">${IDE.esc(c.name)}</span>${hint}</div>`;
      }).join('') || '<div style="padding:12px 16px;color:#8b949e">No matches</div>';
      const selEl = list.querySelector(`[data-idx="${selectedIdx}"]`);
      if (selEl) selEl.scrollIntoView({ block: 'nearest' });
    };

    ide.bus.on('palette:open', () => {
      overlay.style.display = 'flex';
      input.value = '';
      selectedIdx = 0;
      render();
      input.focus();
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
