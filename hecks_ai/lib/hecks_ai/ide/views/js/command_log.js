/* ── Command log — shows bus events, screenshots, and errors ── */
IDE.register({
  init(ide) {
    this.el = document.getElementById('command-log');
    this.ide = ide;
    this.lastScreenshot = null;
    this.errors = [];

    // Toggle collapse on the toggle handle, not the log itself
    // (toggle handle is wired in HTML)

    // Track latest screenshot
    ide.bus.on('screenshot:saved', (path) => { this.lastScreenshot = path; });

    // Track console errors
    ide.bus.on('console:error', (msg) => { this.errors.push(msg); });

    // Log all bus events
    const origEmit = ide.bus.emit.bind(ide.bus);
    ide.bus.emit = (evt, data) => {
      this.logEntry('client', evt, data);
      origEmit(evt, data);
    };
  },

  logEntry(source, event, data) {
    if (['autocomplete:close', 'autocomplete:update'].includes(event)) return;

    const time = new Date().toLocaleTimeString('en-US', {
      hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit'
    });
    const detail = typeof data === 'string' ? data : (data ? JSON.stringify(data).slice(0, 60) : '');
    const screenshot = this.lastScreenshot;
    const errors = this.errors.splice(0); // drain errors

    const entry = document.createElement('div');
    entry.className = 'cmd-entry';

    let html =
      `<span class="cmd-source ${source}">${source}</span>` +
      `<span class="cmd-event">${IDE.esc(event)}</span>`;

    if (detail) html += `<span style="color:var(--fg-dim)">${IDE.esc(detail)}</span>`;

    if (errors.length) {
      html += `<span class="cmd-error" title="${IDE.esc(errors.join('\n'))}">&#9888; ${errors.length}</span>`;
    }

    if (screenshot) {
      html += `<span class="cmd-screenshot" onclick="event.stopPropagation();openScreenshot('${IDE.esc(screenshot)}')" title="View screenshot">&#128247;</span>`;
    }

    html += `<span class="cmd-time">${time}</span>`;
    entry.innerHTML = html;

    // Expand error details on click
    if (errors.length) {
      const errDiv = document.createElement('div');
      errDiv.className = 'cmd-errors hidden';
      errDiv.innerHTML = errors.map(e => `<div class="cmd-error-line">${IDE.esc(e)}</div>`).join('');
      entry.appendChild(errDiv);
      entry.querySelector('.cmd-error').addEventListener('click', (ev) => {
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

/* Open a screenshot in a tab */
function openScreenshot(path) {
  const id = 'screenshot';
  const content = IDE.createTab(id, 'Screenshot');
  IDE.state.openTabs[id].path = path;
  content.innerHTML = `<div style="padding:16px;text-align:center"><img src="/file/${encodeURIComponent(path)}" style="max-width:100%;border-radius:8px;border:1px solid var(--border)"></div>`;
  IDE.switchTab(id);
}
