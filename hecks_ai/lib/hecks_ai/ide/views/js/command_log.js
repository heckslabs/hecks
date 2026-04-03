/* ── Command log — shows bus events, screenshots, and errors ── */
IDE.register({
  init(ide) {
    this.el = document.getElementById('command-log');
    this.ide = ide;
    this.lastScreenshot = null;
    this.errors = [];

    ide.bus.on('screenshot:saved', (path) => { this.lastScreenshot = path; });
    ide.bus.on('console:error', (msg) => { this.errors.push(msg); });

    const origEmit = ide.bus.emit.bind(ide.bus);
    ide.bus.emit = (evt, data) => {
      this.logEntry('client', evt, data);
      origEmit(evt, data);
    };
  },

  logEntry(source, event, data) {
    if (['autocomplete:close', 'autocomplete:update', 'screenshot:saved'].includes(event)) return;

    const time = new Date().toLocaleTimeString('en-US', {
      hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit'
    });
    const detail = typeof data === 'string' ? data : (data ? JSON.stringify(data).slice(0, 60) : '');
    const screenshot = this.lastScreenshot;
    const errors = this.errors.splice(0);

    const entry = document.createElement('div');
    entry.className = 'flex gap-2 py-px';

    const srcColor = source === 'server' ? 'text-accent-yellow' : 'text-accent-blue';
    let html =
      `<span class="min-w-[50px] ${srcColor}">${source}</span>` +
      `<span class="text-fg">${IDE.esc(event)}</span>`;

    if (detail) html += `<span class="text-fg-dim">${IDE.esc(detail)}</span>`;
    if (errors.length) html += `<span class="text-accent-red cursor-pointer" title="${IDE.esc(errors.join('\n'))}">&#9888; ${errors.length}</span>`;
    if (screenshot) html += `<span class="cursor-pointer opacity-60 hover:opacity-100" onclick="event.stopPropagation();openScreenshot('${IDE.esc(screenshot)}')" title="View screenshot">&#128247;</span>`;
    html += `<span class="text-fg-dim ml-auto">${time}</span>`;

    entry.innerHTML = html;

    if (errors.length) {
      const errDiv = document.createElement('div');
      errDiv.className = 'pl-[58px] hidden';
      errDiv.innerHTML = errors.map(e =>
        `<div class="text-accent-red text-[9px] whitespace-nowrap overflow-hidden text-ellipsis">${IDE.esc(e)}</div>`
      ).join('');
      entry.appendChild(errDiv);
      entry.querySelector('.text-accent-red').addEventListener('click', (ev) => {
        ev.stopPropagation();
        errDiv.classList.toggle('hidden');
      });
    }

    this.el.appendChild(entry);
    this.el.scrollTop = this.el.scrollHeight;
  }
});

/* Log server-originated bus events */
(function() {
  const origHandle = IDE.handleEvent;
  if (origHandle) {
    IDE.handleEvent = function(raw) {
      try {
        const e = JSON.parse(raw);
        if (e.type === 'bus') {
          const comp = IDE.components.find(c => c.logEntry);
          if (comp) comp.logEntry('server', e.event, e.data);
        }
      } catch (err) {}
      origHandle.call(IDE, raw);
    };
  }
})();

function openScreenshot(path) {
  const id = 'screenshot';
  const content = IDE.createTab(id, 'Screenshot');
  IDE.state.openTabs[id].path = path;
  content.innerHTML = `<div class="p-4 text-center"><img src="/file/${encodeURIComponent(path)}" class="max-w-full rounded-lg border border-border"></div>`;
  IDE.switchTab(id);
}
