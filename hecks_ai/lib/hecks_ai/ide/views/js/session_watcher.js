/* ── Session watcher — loads history and shows live terminal messages ── */
IDE.register({
  init(ide) {
    ide.bus.on('session:connected', async ({ session_id }) => {
      try {
        const r = await fetch(`/session/history?session_id=${encodeURIComponent(session_id)}&limit=30`);
        const d = await r.json();
        ide.el.msgs.innerHTML = '';
        (d.turns || []).forEach(t => ide.addTurn(t.role, t.text));
        ide.addTurn('system', `Connected to session ${session_id.slice(0, 8)}... (watching)`);
      } catch (e) {
        ide.addTurn('system', `Connected to session ${session_id.slice(0, 8)}...`);
      }
    });
  }
});
