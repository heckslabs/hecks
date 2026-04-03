/* ── Session picker — Cmd+Shift+O or /session ── */
IDE.register({
  onKeydown(e, ide) {
    if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.key === 'O') {
      e.preventDefault();
      ide.bus.emit('session-picker:open');
      return true;
    }
    return false;
  },

  init(ide) {
    const overlay = document.createElement('div');
    overlay.id = 'session-picker';
    overlay.style.cssText = 'display:none;position:fixed;inset:0;background:rgba(0,0,0,0.6);z-index:50;align-items:flex-start;justify-content:center;padding-top:15vh;';

    const box = document.createElement('div');
    box.style.cssText = 'background:#161b22;border:1px solid #30363d;border-radius:8px;width:500px;max-height:450px;overflow-y:auto;font-family:SF Mono,Fira Code,Menlo,monospace;font-size:13px;';

    const header = document.createElement('div');
    header.style.cssText = 'padding:12px 16px;border-bottom:1px solid #30363d;color:#7ee787;font-size:11px;text-transform:uppercase;letter-spacing:0.5px;display:flex;justify-content:space-between;';
    header.innerHTML = '<span>Resume Session</span><span style="color:#8b949e">Cmd+Shift+O</span>';

    const list = document.createElement('div');
    box.appendChild(header);
    box.appendChild(list);
    overlay.appendChild(box);
    document.body.appendChild(overlay);

    let sessions = [];
    let selectedIdx = 0;
    const currentId = localStorage.getItem('hecks-ide-session');

    const close = () => {
      overlay.style.display = 'none';
      ide.el.prompt.focus();
    };

    const render = () => {
      const currentId = localStorage.getItem('hecks-ide-session');
      // Sort current session to top
      const sorted = [...sessions].sort((a, b) => {
        if (a.id === currentId) return -1;
        if (b.id === currentId) return 1;
        return 0;
      });

      list.innerHTML = sorted.map((s, i) => {
        const sel = i === selectedIdx ? 'background:#1c2333;' : '';
        const isCurrent = s.id === currentId;
        const border = isCurrent ? 'border-left:3px solid #7ee787;' : '';
        const badge = isCurrent ? '<span style="color:#7ee787;font-size:9px;margin-left:6px;text-transform:uppercase">active</span>' : '';
        const preview = IDE.esc(s.preview || '').slice(0, 60);
        return `<div data-idx="${i}" style="padding:8px 16px;cursor:pointer;${sel}${border}" onclick="pickSession('${s.id}')">` +
          `<div style="display:flex;justify-content:space-between"><span style="color:#c9d1d9">${preview || '(empty)'}${badge}</span><span style="color:#8b949e;font-size:10px">${s.age}</span></div>` +
          `<div style="color:#8b949e;font-size:10px;margin-top:2px">${s.id.slice(0,8)}...</div></div>`;
      }).join('') || '<div style="padding:16px;color:#8b949e">No sessions found</div>';

      list.innerHTML += '<div style="padding:8px 16px;cursor:pointer;color:#58a6ff;border-top:1px solid #30363d" onclick="pickSession(\'new\')">+ New session</div>';

      const selEl = list.querySelector(`[data-idx="${selectedIdx}"]`);
      if (selEl) selEl.scrollIntoView({ block: 'nearest' });
    };

    ide.bus.on('session-picker:open', async () => {
      overlay.style.display = 'flex';
      selectedIdx = 0;
      try {
        const r = await fetch('/sessions');
        const d = await r.json();
        sessions = d.sessions || [];
      } catch (e) { sessions = []; }
      render();
      overlay.focus();
    });

    overlay.addEventListener('click', e => { if (e.target === overlay) close(); });

    overlay.setAttribute('tabindex', '-1');
    overlay.addEventListener('keydown', e => {
      if (e.key === 'Escape') { close(); return; }
      if (e.key === 'ArrowDown') { e.preventDefault(); selectedIdx = Math.min(selectedIdx + 1, sessions.length); render(); return; }
      if (e.key === 'ArrowUp') { e.preventDefault(); selectedIdx = Math.max(selectedIdx - 1, 0); render(); return; }
      if (e.key === 'Enter') {
        if (selectedIdx < sessions.length) {
          close(); pickSession(sessions[selectedIdx].id);
        } else {
          close(); pickSession('new');
        }
        return;
      }
    });

    // Auto-resume last session on boot
    if (currentId) {
      ide.bus.on('prompt:send', function autoResume() {
        // Resume on first prompt only
        fetch('/session/resume', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ session_id: currentId })
        }).catch(() => {});
        // Remove this one-time listener
        const idx = ide.bus._subs['prompt:send'].indexOf(autoResume);
        if (idx >= 0) ide.bus._subs['prompt:send'].splice(idx, 1);
      });
    }
  }
});

/* Global for onclick in rendered HTML */
async function pickSession(id) {
  document.getElementById('session-picker').style.display = 'none';

  if (id === 'new') {
    localStorage.removeItem('hecks-ide-session');
    IDE.addTurn('system', 'Starting new session');
    return;
  }

  try {
    await fetch('/session/resume', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ session_id: id })
    });
    localStorage.setItem('hecks-ide-session', id);
    IDE.bus.emit('session:connected', { session_id: id });
  } catch (e) {
    IDE.addTurn('system', 'Failed to resume session');
  }
}
