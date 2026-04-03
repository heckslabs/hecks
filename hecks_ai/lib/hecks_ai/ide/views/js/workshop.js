/* ── Workshop component ── */
IDE.register({
  handleWorkshop(text, ide) {
    this.sendCommand(text, ide);
    return true;
  },

  async sendCommand(cmd, ide) {
    const out = document.getElementById('ws-output');
    const scroller = out.closest('.tab-content');
    const entry = document.createElement('div');
    entry.className = 'mb-3';
    entry.innerHTML = `<div class="text-accent-green ws-cmd">${ide.esc(cmd)}</div>`;
    out.appendChild(entry);
    scroller.scrollTo({ top: scroller.scrollHeight, behavior: 'smooth' });

    const r = await fetch('/workshop/command', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ command: cmd })
    });
    const d = await r.json();
    ide.state.wsCompletions = d.completions || ide.state.wsCompletions;
    if (d.state?.aggregates) {
      ide.state.wsAggAttrs = {};
      d.state.aggregates.forEach(a => {
        ide.state.wsAggAttrs[a.name.toLowerCase()] = a.attributes.map(at => at.name);
      });
    }

    if (d.error) entry.innerHTML += `<div class="whitespace-pre-wrap break-words mt-1 text-accent-red">${ide.esc(d.error)}</div>`;
    else if (d.output) entry.innerHTML += `<div class="whitespace-pre-wrap break-words mt-1">${ide.esc(d.output)}</div>`;
    scroller.scrollTo({ top: scroller.scrollHeight, behavior: 'smooth' });

    console.log('workshop state:', d.state?.mode, 'events:', d.state?.events?.length);
    if (d.state?.mode === 'play') {
      ide.el.eventsSidebar.classList.add('open');
      const events = d.state.events || [];
      if (!events.length) {
        ide.el.eventList.innerHTML = '<div class="event-empty">No events yet. Run a command.</div>';
      } else {
        ide.el.eventList.innerHTML = events.map(ev => {
          const attrs = Object.entries(ev.attributes || {}).map(([k,v]) => `${k}: ${v}`).join(', ');
          return `<div class="${IDE.tw.eventItem}"><span class="${IDE.tw.eventType}">${ide.esc(ev.type)}</span><div class="${IDE.tw.eventAttrs}">${ide.esc(attrs)}</div></div>`;
        }).join('');
      }
    }
  }
});

/* ── Workshop bus wiring ── */
IDE.bus.on('workshop:open', (data) => openWorkshop(data.path, data.name));

/* ── Workshop global functions (called from HTML onclick) ── */

async function openWorkshop(path, name) {
  const r = await fetch('/workshop/open', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ path })
  });
  const d = await r.json();
  IDE.state.wsCompletions = d.completions || [];
  if (d.state?.aggregates) {
    IDE.state.wsAggAttrs = {};
    d.state.aggregates.forEach(a => {
      IDE.state.wsAggAttrs[a.name.toLowerCase()] = a.attributes.map(at => at.name);
    });
  }
  IDE.state.wsActive = true;

  const id = 'workshop';
  if (!IDE.state.openTabs[id]) {
    const content = IDE.createTab(id, name);
    content.innerHTML =
      `<div class="p-4 text-center border-b border-border"><div class="font-mono text-[13px] text-accent-green font-semibold mb-3">${IDE.esc(d.domain)}</div><pre class="mermaid-pending">${IDE.esc(d.diagram || '')}</pre></div>` +
      `<div class="p-4 font-mono text-[13px] leading-relaxed" id="ws-output"><div class="mb-3"><span class="text-fg-dim text-[11px]">Workshop: ${IDE.esc(d.domain)} (sketch mode)</span></div></div>`;
    IDE.state.openTabs[id].path = path;
  } else {
    IDE.state.openTabs[id].tab.querySelector('.tab-label').textContent = name;
    document.getElementById('ws-output').innerHTML =
      `<div class="mb-3"><span class="text-fg-dim text-[11px]">Workshop: ${IDE.esc(d.domain)} (sketch mode)</span></div>`;
  }
  IDE.switchTab(id);
  IDE.el.prompt.placeholder = `${d.domain} workshop > `;
  setTimeout(() => { if (window.renderMermaid) window.renderMermaid(); }, 100);
}

function closeWorkshop() {
  IDE.state.wsActive = false;
  IDE.closeTab('workshop');
  IDE.el.prompt.placeholder = 'Type a message...';
  IDE.el.eventsSidebar.classList.remove('open');
}
