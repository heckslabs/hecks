/* ── Command log — shows all bus events above the prompt ── */
IDE.register({
  init(ide) {
    this.el = document.getElementById('command-log');
    this.ide = ide;

    this.el.addEventListener('click', () => this.el.classList.toggle('collapsed'));

    // Log all bus events
    const origEmit = ide.bus.emit.bind(ide.bus);
    ide.bus.emit = (evt, data) => {
      this.log('client', evt, data);
      origEmit(evt, data);
    };
  },

  log(source, event, data) {
    // Skip noisy events
    if (['autocomplete:close', 'autocomplete:update'].includes(event)) return;

    const time = new Date().toLocaleTimeString('en-US', { hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit' });
    const detail = typeof data === 'string' ? data : (data ? JSON.stringify(data).slice(0, 60) : '');
    const entry = document.createElement('div');
    entry.className = 'cmd-entry';
    entry.innerHTML =
      `<span class="cmd-source ${source}">${source}</span>` +
      `<span class="cmd-event">${IDE.esc(event)}</span>` +
      (detail ? `<span style="color:var(--fg-dim)">${IDE.esc(detail)}</span>` : '') +
      `<span class="cmd-time">${time}</span>`;
    this.el.appendChild(entry);
    this.el.scrollTop = this.el.scrollHeight;
  }
});

/* Also log server-originated bus events */
(function() {
  const origHandle = IDE.handleEvent;
  if (origHandle) {
    IDE.handleEvent = function(raw) {
      try {
        const e = JSON.parse(raw);
        if (e.type === 'bus') {
          const comp = IDE.components.find(c => c.log);
          if (comp) comp.log('server', e.event, e.data);
        }
      } catch (err) {}
      origHandle.call(IDE, raw);
    };
  }
})();
