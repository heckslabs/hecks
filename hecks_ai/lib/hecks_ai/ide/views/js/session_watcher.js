/* ── Session watcher — loads history, banner, live terminal messages ── */
IDE.register({
  init(ide) {
    const banner = document.getElementById('session-banner');
    const bannerText = document.getElementById('session-banner-text');

    ide.bus.on('session:connected', async ({ session_id }) => {
      banner.classList.remove('hidden');
      bannerText.textContent = `Session ${session_id.slice(0, 8)}...`;
      try {
        const r = await fetch(`/session/history?session_id=${encodeURIComponent(session_id)}&limit=30`);
        const d = await r.json();
        ide.el.msgs.innerHTML = '';
        const turns = d.turns || [];
        let lastUserEl = null;
        turns.forEach(t => {
          const el = ide.addTurn(t.role, t.text);
          if (t.role === 'user') lastUserEl = el;
          else lastUserEl = null;
        });
        if (lastUserEl) lastUserEl.classList.add('thinking');
      } catch (e) {
        ide.addTurn('system', `Connected to ${session_id.slice(0, 8)}...`);
      }
    });

    ide.bus.on('session:disconnect', async () => {
      banner.classList.add('hidden');
      bannerText.textContent = '';
      try { await fetch('/session/disconnect', { method: 'POST' }); } catch (e) {}
      localStorage.removeItem('hecks-ide-session');
      ide.addTurn('system', 'Disconnected');
    });
  }
});
