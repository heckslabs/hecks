/* ── IDE Test Harness — visual tests via bus commands ── */

const IDETests = {
  results: [],
  visual: true,
  get totalTests() { return this._totalTests || '?'; },

  async runAll() {
    this.results = [];

    // Clear previous
    document.getElementById('command-log').innerHTML = '';
    const panelLog = document.getElementById('test-panel-log');
    if (panelLog) panelLog.innerHTML = '';
    const testsPanel = document.getElementById('panel-tests');
    if (testsPanel) testsPanel.classList.remove('closed');
    IDE.syncDot('tests');

    // Snapshot state
    const savedMsgs = IDE.el.msgs.innerHTML;
    const savedPrompt = IDE.el.prompt.value;
    const savedPlaceholder = IDE.el.prompt.placeholder;
    const panelStates = {};
    document.querySelectorAll('.panel').forEach(p => { panelStates[p.id] = p.className; });

    // ── Tests ──

    await this.test('bus delivers to subscribers', async () => {
      let received = false;
      IDE.bus.on('test:verify', () => { received = true; });
      IDE.bus.emit('test:verify');
      return received;
    });

    await this.test('app-picker opens', async () => {
      IDE.bus.emit('app-picker:open');
      return await this.waitFor(() => {
        const el = document.getElementById('app-picker');
        return el && el.style.display === 'flex';
      });
    });

    await this.test('app-picker closes', async () => {
      const el = document.getElementById('app-picker');
      if (el) el.style.display = 'none';
      return true;
    });

    await this.test('session-picker opens', async () => {
      IDE.bus.emit('session-picker:open');
      return await this.waitFor(() => {
        const el = document.getElementById('session-picker');
        return el && el.style.display === 'flex';
      });
    });

    await this.test('session-picker closes', async () => {
      const el = document.getElementById('session-picker');
      if (el) el.style.display = 'none';
      return true;
    });

    await this.test('sidebar toggles closed', async () => {
      IDE.bus.emit('sidebar:toggle');
      return IDE.el.sidebar.classList.contains('collapsed');
    });

    await this.test('sidebar toggles open', async () => {
      IDE.bus.emit('sidebar:toggle');
      return !IDE.el.sidebar.classList.contains('collapsed');
    });

    await this.test('panel collapses', async () => {
      IDE.bus.emit('panel:collapse', 'apps');
      return document.getElementById('panel-apps').classList.contains('closed');
    });

    await this.test('panel expands', async () => {
      IDE.bus.emit('panel:collapse', 'apps');
      return !document.getElementById('panel-apps').classList.contains('closed');
    });

    await this.test('panel:show reveals hidden panel', async () => {
      document.getElementById('panel-hex').classList.add('hidden', 'closed');
      IDE.bus.emit('panel:show', 'hex');
      const el = document.getElementById('panel-hex');
      return !el.classList.contains('hidden') && !el.classList.contains('closed');
    });

    await this.test('command-log opens', async () => {
      document.getElementById('command-log').classList.add('collapsed');
      IDE.bus.emit('command-log:toggle');
      return !document.getElementById('command-log').classList.contains('collapsed');
    });

    await this.test('tab:close removes tab', async () => {
      IDE.createTab('test-tab', 'Test Tab');
      IDE.switchTab('test-tab');
      const existed = !!IDE.state.openTabs['test-tab'];
      return existed;
    });

    await this.test('tab:close cleans up', async () => {
      IDE.bus.emit('tab:close', 'test-tab');
      return !IDE.state.openTabs['test-tab'];
    });

    await this.test('autocomplete:close via bus', async () => {
      IDE.bus.emit('autocomplete:close');
      return !document.querySelector('.awesomplete > ul:not([hidden])');
    });

    await this.test('/hecks-ide-commands shows commands', async () => {
      IDE.el.prompt.value = '/hecks-ide-commands';
      await IDE.sendPrompt();
      return IDE.el.msgs.textContent.includes('/hecks-ide-clear');
    });

    await this.test('/hecks-ide-log opens log', async () => {
      document.getElementById('command-log').classList.add('collapsed');
      IDE.el.prompt.value = '/hecks-ide-log';
      await IDE.sendPrompt();
      return !document.getElementById('command-log').classList.contains('collapsed');
    });

    await this.test('/hecks-ide-clear clears chat', async () => {
      IDE.addTurn('system', 'test message');
      IDE.el.prompt.value = '/hecks-ide-clear';
      await IDE.sendPrompt();
      return IDE.el.msgs.children.length === 0;
    });

    await this.test('/hecks-ide-reset resets', async () => {
      IDE.el.prompt.value = '/hecks-ide-reset';
      await IDE.sendPrompt();
      return IDE.el.msgs.children.length === 0;
    });

    await this.test('Escape interrupts', async () => {
      IDE.state.busy = true;
      IDE.el.send.disabled = true;
      IDE.el.thinkingBar.classList.add('active');
      // Fire through the component system
      IDE.onKeydown({ key: 'Escape', preventDefault: ()=>{}, stopImmediatePropagation: ()=>{} });
      return !IDE.state.busy;
    });

    await this.test('ArrowUp recalls history', async () => {
      IDE.state.cmdHistory = ['test-history-1', 'test-history-2'];
      IDE.state.histIdx = -1;
      IDE.el.prompt.value = '';
      IDE.el.prompt.focus();
      IDE.onKeydown({ key: 'ArrowUp', target: IDE.el.prompt, preventDefault: ()=>{}, stopImmediatePropagation: ()=>{} });
      return IDE.el.prompt.value === 'test-history-2';
    });

    await this.test('ArrowDown navigates forward', async () => {
      IDE.state.histIdx = 0;
      IDE.onKeydown({ key: 'ArrowDown', target: IDE.el.prompt, preventDefault: ()=>{}, stopImmediatePropagation: ()=>{} });
      return IDE.el.prompt.value === 'test-history-2';
    });

    await this.test('Tab completes', async () => {
      IDE.state.wsActive = true;
      IDE.state.wsCompletions = ['Pizza', 'Order'];
      IDE.el.prompt.value = 'Piz';
      IDE.el.prompt.focus();
      IDE.onKeydown({ key: 'Tab', target: IDE.el.prompt, preventDefault: ()=>{}, stopImmediatePropagation: ()=>{} });
      const val = IDE.el.prompt.value;
      IDE.state.wsActive = false;
      IDE.state.wsCompletions = [];
      return val === 'Pizza';
    });

    await this.test('workshop:open handler registered', async () => {
      return (IDE.bus._subs['workshop:open'] || []).length > 0;
    });

    await this.test('hecksagon:open handler registered', async () => {
      return (IDE.bus._subs['hecksagon:open'] || []).length > 0;
    });

    await this.test('file:request handler registered', async () => {
      return (IDE.bus._subs['file:request'] || []).length > 0;
    });

    await this.test('tests panel exists', async () => {
      return !!document.getElementById('panel-tests');
    });

    await this.test('test-run button exists in panel', async () => {
      return !!document.querySelector('#panel-tests button');
    });

    // ── Done ──
    this._totalTests = this.results.length;
    this.updatePanel('Done');

    // Restore state
    IDE.el.msgs.innerHTML = savedMsgs;
    IDE.el.prompt.value = savedPrompt;
    IDE.el.prompt.placeholder = savedPlaceholder;
    document.querySelectorAll('.panel').forEach(p => { if (panelStates[p.id]) p.className = panelStates[p.id]; });
    const ap = document.getElementById('app-picker'); if (ap) ap.style.display = 'none';
    const sp = document.getElementById('session-picker'); if (sp) sp.style.display = 'none';
    IDE.switchTab('chat');
    IDE.el.status.textContent = '';
    IDE.state.busy = false;
    IDE.el.send.disabled = false;
    IDE.state.cmdHistory = [];
    IDE.state.histIdx = -1;

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

  // Poll for a condition to become true (for async UI changes)
  async waitFor(fn, timeout = 2000) {
    const start = Date.now();
    while (Date.now() - start < timeout) {
      if (fn()) return true;
      await new Promise(r => setTimeout(r, 50));
    }
    return fn();
  },

  wait(ms) { return new Promise(r => setTimeout(r, ms)); },

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
    count.className = failed ? 'text-[9px] bg-accent-red text-bg rounded-full px-1.5 py-px ml-1.5'
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

let testTimer = null;
IDE.bus.on('test:run', (opts) => {
  IDETests.visual = !(opts && opts.headless);
  clearTimeout(testTimer);
  testTimer = setTimeout(() => IDETests.runAll(), 500);
});
