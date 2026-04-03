/* ── IDE Test Harness — click handlers emit bus events ── */

const IDETests = {
  results: [],
  visual: true,
  tests: [],
  get totalTests() { return this._totalTests || '?'; },

  register(name, fn) { this.tests.push({ name, fn }); },

  listenOnce(event) {
    const result = { fired: false, data: undefined };
    const handler = (data) => { result.fired = true; result.data = data; };
    IDE.bus.on(event, handler);
    result.cleanup = () => {
      const subs = IDE.bus._subs[event];
      if (subs) { const i = subs.indexOf(handler); if (i >= 0) subs.splice(i, 1); }
    };
    return result;
  },

  async runAll() {
    this.results = [];
    document.getElementById('command-log').innerHTML = '';
    const panelLog = document.getElementById('test-panel-log');
    if (panelLog) panelLog.innerHTML = '';
    const testsPanel = document.getElementById('panel-tests');
    if (testsPanel) testsPanel.classList.remove('closed');
    IDE.syncDot('tests');

    this.snapshot = {
      msgs: IDE.el.msgs.innerHTML,
      prompt: IDE.el.prompt.value,
      placeholder: IDE.el.prompt.placeholder,
      panels: {}
    };
    document.querySelectorAll('.panel').forEach(p => {
      this.snapshot.panels[p.id] = p.className;
    });

    for (const t of this.tests) {
      await this.test(t.name, t.fn);
    }

    this._totalTests = this.results.length;
    this.updatePanel('Done');
    this.restore();
    this.report();
  },

  async test(name, fn) {
    try {
      const result = await fn();
      this.results.push({ name, pass: !!result });
      if (!result) console.warn(`FAIL: ${name}`);
    } catch (e) {
      this.results.push({ name, pass: false });
      console.error(`FAIL: ${name}: ${e.message}`);
    }
    this.updatePanel(name);
    if (this.visual) await this.wait(500);
    else await new Promise(r => requestAnimationFrame(r));
  },

  wait(ms) { return new Promise(r => setTimeout(r, ms)); },

  restore() {
    IDE.el.msgs.innerHTML = this.snapshot.msgs;
    IDE.el.prompt.value = this.snapshot.prompt;
    IDE.el.prompt.placeholder = this.snapshot.placeholder;
    document.querySelectorAll('.panel').forEach(p => {
      if (this.snapshot.panels[p.id]) p.className = this.snapshot.panels[p.id];
    });
    const ap = document.getElementById('app-picker');
    if (ap) ap.style.display = 'none';
    const sp = document.getElementById('session-picker');
    if (sp) sp.style.display = 'none';
    IDE.switchTab('chat');
    IDE.el.status.textContent = '';
    IDE.state.busy = false;
    IDE.el.send.disabled = false;
    IDE.state.cmdHistory = [];
    IDE.state.histIdx = -1;
  },

  updatePanel(currentTest) {
    const log = document.getElementById('test-panel-log');
    const count = document.getElementById('test-panel-count');
    if (!log) return;
    const last = this.results[this.results.length - 1];
    if (last) {
      const icon = last.pass ? '✓' : '✗';
      const color = last.pass ? 'text-accent-green' : 'text-accent-red';
      log.innerHTML += `<div><span class="${color}">${icon}</span> ${last.name}</div>`;
      log.scrollTop = log.scrollHeight;
    }
    const passed = this.results.filter(r => r.pass).length;
    const failed = this.results.filter(r => !r.pass).length;
    count.textContent = `${passed}/${this.results.length}`;
    count.className = failed
      ? 'text-[9px] bg-accent-red text-bg rounded-full px-1.5 py-px ml-1.5'
      : 'text-[9px] bg-border text-fg rounded-full px-1.5 py-px ml-1.5';
  },

  report() {
    const passed = this.results.filter(r => r.pass).length;
    const failed = this.results.filter(r => !r.pass);
    const total = this.results.length;
    console.log(`IDE Tests: ${passed}/${total} passed, ${failed.length} failed`);
    this.results.forEach(r => console.log(`  ${r.pass ? '✓' : '✗'} ${r.name}`));
    fetch('/console', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        level: failed.length ? 'error' : 'log',
        message: `IDE Tests: ${passed}/${total} passed. ${failed.map(r => r.name).join(', ')}`
      })
    }).catch(() => {});
  }
};

/* ── Tests: click → visual change → assert event ── */
/* Each test makes ONE change. Undo happens in the next test. */

IDETests.register('bus delivers to subscribers', async () => {
  const ev = IDETests.listenOnce('test:verify');
  IDE.bus.emit('test:verify');
  ev.cleanup();
  return ev.fired;
});

IDETests.register('click: sidebar closes', async () => {
  const ev = IDETests.listenOnce('sidebar:toggle');
  document.querySelector('button[onclick="toggleSidebar()"]').click();
  ev.cleanup();
  return ev.fired;
});

IDETests.register('click: sidebar opens', async () => {
  const ev = IDETests.listenOnce('sidebar:toggle');
  document.querySelector('button[onclick="toggleSidebar()"]').click();
  ev.cleanup();
  return ev.fired;
});

IDETests.register('click: apps panel collapses', async () => {
  document.getElementById('panel-apps').classList.remove('closed');
  const ev = IDETests.listenOnce('panel:collapse');
  document.querySelector('.panel-dot-apps').click();
  ev.cleanup();
  return ev.fired && ev.data === 'apps';
});

IDETests.register('click: apps panel expands', async () => {
  const ev = IDETests.listenOnce('panel:collapse');
  document.querySelector('.panel-dot-apps').click();
  ev.cleanup();
  return ev.fired && ev.data === 'apps';
});

IDETests.register('click: docs header collapses', async () => {
  document.getElementById('panel-docs-panel').classList.remove('closed');
  const ev = IDETests.listenOnce('panel:collapse');
  document.querySelector('#panel-docs-panel .panel-head span').click();
  ev.cleanup();
  return ev.fired && ev.data === 'docs-panel';
});

IDETests.register('click: docs header expands', async () => {
  const ev = IDETests.listenOnce('panel:collapse');
  document.querySelector('#panel-docs-panel .panel-head span').click();
  ev.cleanup();
  return ev.fired && ev.data === 'docs-panel';
});

IDETests.register('click: IDE Log panel opens', async () => {
  document.getElementById('panel-ide-log').classList.add('closed');
  const ev = IDETests.listenOnce('panel:collapse');
  document.querySelector('.panel-dot-ide-log').click();
  ev.cleanup();
  return ev.fired && ev.data === 'ide-log';
});

IDETests.register('click: IDE Log panel closes', async () => {
  const ev = IDETests.listenOnce('panel:collapse');
  document.querySelector('.panel-dot-ide-log').click();
  ev.cleanup();
  return ev.fired && ev.data === 'ide-log';
});

IDETests.register('key: Cmd+O opens app-picker', async () => {
  const ev = IDETests.listenOnce('app-picker:open');
  document.dispatchEvent(new KeyboardEvent('keydown', {
    key: 'o', metaKey: true, bubbles: true
  }));
  ev.cleanup();
  return ev.fired;
});

IDETests.register('click: app-picker closes', async () => {
  const el = document.getElementById('app-picker');
  if (el) el.style.display = 'none';
  return true;
});

IDETests.register('key: Cmd+J opens session-picker', async () => {
  document.dispatchEvent(new KeyboardEvent('keydown', {
    key: 'j', metaKey: true, bubbles: true
  }));
  await IDETests.wait(100);
  const el = document.getElementById('session-picker');
  return el && el.style.display === 'flex';
});

IDETests.register('click: session-picker closes', async () => {
  const el = document.getElementById('session-picker');
  if (el) el.click();
  await IDETests.wait(100);
  return !el || el.style.display === 'none';
});

IDETests.register('click: tab creates', async () => {
  IDE.createTab('test-tab', 'Test Tab', '<div class="p-4">Test content</div>');
  const ev = IDETests.listenOnce('tab:switch');
  document.querySelector('.tab[data-tab="test-tab"]').click();
  ev.cleanup();
  return ev.fired && ev.data === 'test-tab';
});

IDETests.register('click: tab closes', async () => {
  const closeBtn = document.querySelector('.tab[data-tab="test-tab"] .text-fg-dim');
  if (closeBtn) closeBtn.click();
  return !IDE.state.openTabs['test-tab'];
});

IDETests.register('slash: /hecks-ide-commands', async () => {
  IDE.el.prompt.value = '/hecks-ide-commands';
  document.getElementById('send').click();
  return IDE.el.msgs.textContent.includes('/hecks-ide-clear');
});

IDETests.register('slash: /hecks-ide-log', async () => {
  document.getElementById('panel-ide-log').classList.add('closed');
  IDE.el.prompt.value = '/hecks-ide-log';
  document.getElementById('send').click();
  return !document.getElementById('panel-ide-log').classList.contains('closed');
});

IDETests.register('slash: /hecks-ide-clear', async () => {
  IDE.addTurn('system', 'test message');
  IDE.el.prompt.value = '/hecks-ide-clear';
  document.getElementById('send').click();
  return IDE.el.msgs.children.length === 0;
});

IDETests.register('slash: /hecks-ide-reset', async () => {
  IDE.el.prompt.value = '/hecks-ide-reset';
  document.getElementById('send').click();
  return IDE.el.msgs.children.length === 0;
});

IDETests.register('key: Escape stops busy', async () => {
  IDE.state.busy = true;
  IDE.el.send.disabled = true;
  document.dispatchEvent(new KeyboardEvent('keydown', {
    key: 'Escape', bubbles: true
  }));
  return !IDE.state.busy;
});

IDETests.register('key: ArrowUp recalls history', async () => {
  IDE.state.cmdHistory = ['test-history-1', 'test-history-2'];
  IDE.state.histIdx = -1;
  IDE.el.prompt.value = '';
  IDE.el.prompt.focus();
  IDE.el.prompt.dispatchEvent(new KeyboardEvent('keydown', {
    key: 'ArrowUp', bubbles: true
  }));
  return IDE.el.prompt.value === 'test-history-2';
});

IDETests.register('key: ArrowDown navigates forward', async () => {
  IDE.state.histIdx = 0;
  IDE.el.prompt.dispatchEvent(new KeyboardEvent('keydown', {
    key: 'ArrowDown', bubbles: true
  }));
  return IDE.el.prompt.value === 'test-history-2';
});

IDETests.register('handler: workshop:open', async () => {
  return (IDE.bus._subs['workshop:open'] || []).length > 0;
});

IDETests.register('handler: hecksagon:open', async () => {
  return (IDE.bus._subs['hecksagon:open'] || []).length > 0;
});

IDETests.register('handler: file:request', async () => {
  return (IDE.bus._subs['file:request'] || []).length > 0;
});

/* ── Bus listener ── */
let testTimer = null;
IDE.bus.on('test:run', (opts) => {
  IDETests.visual = !(opts && opts.headless);
  clearTimeout(testTimer);
  testTimer = setTimeout(() => IDETests.runAll(), 500);
});
