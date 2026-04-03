/* ── Hecksagon tab viewer with diagram ── */
IDE.bus.on('hecksagon:open', (path) => openHecksagon(path));

function openHecksagon(path) {
  IDE.showPanel('hex');
  document.querySelector('.panel-dot-hex').classList.remove('inactive');

  fetch('/file/' + encodeURIComponent(path))
    .then(r => r.text())
    .then(text => {
      // Sidebar panel preview
      document.getElementById('hex-body').innerHTML =
        '<div class="file-view-path">' + IDE.esc(path) + '</div>' +
        '<pre style="font-size:11px;line-height:1.5;white-space:pre-wrap">' + IDE.esc(text) + '</pre>';

      // Main tab with diagram + source
      const name = path.split('/').pop();
      const content = IDE.createTab('hecksagon', name);
      IDE.state.openTabs['hecksagon'].path = path;
      const diagram = buildHecksagonDiagram(text, path);
      content.innerHTML =
        '<div class="ws-diagram"><div class="ws-diagram-title">' + IDE.esc(name) + '</div>' +
        '<pre class="mermaid-pending">' + IDE.esc(diagram) + '</pre></div>' +
        '<div class="file-view"><div class="file-view-path">' + IDE.esc(path) + '</div>' +
        '<pre>' + IDE.esc(text) + '</pre></div>';

      IDE.switchTab('hecksagon');
      setTimeout(() => { if (window.renderMermaid) window.renderMermaid(); }, 200);
    })
    .catch(e => console.error('openHecksagon error:', e));
}

function buildHecksagonDiagram(text, path) {
  const name = path.split('/').pop().replace(/Hecksagon$/, '');
  const caps = [...text.matchAll(/capabilities\s+(.+)/g)].map(m => m[1].trim());
  const tags = [...text.matchAll(/capability\.(\w+)\.(\w+)/g)].map(m => `${m[1]}.${m[2]}`);
  const gates = [...text.matchAll(/gate\s+"(\w+)",\s*:(\w+)\s+do\s*\n\s*allow\s+([^\n]+)/g)]
    .map(m => ({ agg: m[1], role: m[2], methods: m[3].trim() }));
  const adapter = text.match(/adapter\s+:(\w+)/)?.[1];
  const tenancy = text.match(/tenancy\s+:(\w+)/)?.[1];

  let d = 'graph TD\n';
  d += `  H["${name} Hecksagon"]\n`;
  if (adapter) d += `  DB[("${adapter}")]\n  H --> DB\n`;
  if (tenancy) d += `  T["tenancy: ${tenancy}"]\n  H -.-> T\n`;
  caps.forEach(c => {
    c.split(/[,\s]+:?/).filter(Boolean).forEach(cap => {
      const cl = cap.replace(/^:/, '');
      d += `  ${cl}["${cl}"]\n  H -->|capability| ${cl}\n`;
    });
  });
  tags.forEach(t => {
    const [attr, tag] = t.split('.');
    d += `  ${attr}_${tag}["${attr}.${tag}"]\n  H -.-> ${attr}_${tag}\n`;
  });
  const aggGates = {};
  gates.forEach(g => { (aggGates[g.agg] ||= []).push(g); });
  for (const [agg, gs] of Object.entries(aggGates)) {
    const roles = gs.map(g => `${g.role}: ${g.methods}`).join('<br/>');
    d += `  ${agg}["${agg}<br/><small>${roles}</small>"]\n  H --> ${agg}\n`;
  }
  return d;
}
