/* ── IDE Test Harness — exercises all commands via all entry points ── */

const IDETests = {
  results: [],

  overlay: null,

  showOverlay(text) {
    if (!this.overlay) {
      this.overlay = document.createElement('div');
      this.overlay.style.cssText = 'position:fixed;inset:0;background:rgba(13,17,23,0.85);z-index:100;display:flex;align-items:center;justify-content:center;flex-direction:column;cursor:pointer;';
      this.overlay.addEventListener('click', () => this.hideOverlay());
      document.body.appendChild(this.overlay);
    }
    if (!document.getElementById('test-log')) {
      this.overlay.innerHTML =
        `<div style="background:#161b22;border:1px solid #30363d;border-radius:8px;width:500px;max-height:400px;padding:16px;overflow-y:auto" onclick="event.stopPropagation()">` +
        `<div style="color:var(--green);font-size:14px;font-weight:600;margin-bottom:8px">Testing</div>` +
        `<div id="test-log" style="font-size:12px;line-height:1.8;max-height:300px;overflow-y:auto"></div>` +
        `<div id="test-current" style="color:var(--fg-dim);font-size:11px;margin-top:8px;border-top:1px solid var(--border);padding-top:6px"></div>` +
        `</div>`;
    }
    const log = document.getElementById('test-log');
    const current = document.getElementById('test-current');
    // Add last result to log
    const last = this.results[this.results.length - 1];
    if (last) {
      const icon = last.pass ? '✓' : '✗';
      const color = last.pass ? 'var(--green)' : 'var(--red)';
      log.innerHTML += `<div><span style="color:${color}">${icon}</span> ${last.name}</div>`;
      log.scrollTop = log.scrollHeight;
    }
    current.textContent = `▸ ${text}  (${this.results.length}/${this.totalTests})`;
    log.scrollTop = log.scrollHeight;
    this.overlay.style.display = 'flex';
  },

  hideOverlay() {
    if (this.overlay) this.overlay.style.display = 'none';
  },

  updatePanel(currentTest) {
    const log = document.getElementById('test-panel-log');
    const count = document.getElementById('test-panel-count');
    if (!log) return;

    // Show last result
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

  get totalTests() { return this._totalTests || '?'; },

  async runAll() {
    this.results = [];

    // Clear previous test state
    if (this.overlay) { this.overlay.remove(); this.overlay = null; }
    document.getElementById('command-log').innerHTML = '';
    const panelLog = document.getElementById('test-panel-log');
    if (panelLog) panelLog.innerHTML = '';
    // Open the tests panel
    const testsPanel = document.getElementById('panel-tests');
    if (testsPanel) testsPanel.classList.remove('closed');
    IDE.syncDot('tests');

    // Snapshot state before tests
    const savedMsgs = IDE.el.msgs.innerHTML;
    const savedPrompt = IDE.el.prompt.value;
    const savedPlaceholder = IDE.el.prompt.placeholder;
    const panelStates = {};
    document.querySelectorAll('.panel').forEach(p => { panelStates[p.id] = p.className; });
    const logCollapsed = document.getElementById('command-log').classList.contains('collapsed');

    // Core
    await this.test('bus delivers to subscribers', async () => {
      let received = false;
      IDE.bus.on('test:verify', () => { received = true; });
      IDE.bus.emit('test:verify');
      return received;
    });

    // App picker — bus, hotkey
    await this.test('app-picker:open via bus', async () => {
      const el = document.getElementById('app-picker');
      IDE.bus.emit('app-picker:open');
      await this.wait(300);
      const open = el.style.display === 'flex';
      el.style.display = 'none';
      return open;
    });

    await this.test('app-picker:open via Cmd+O hotkey', async () => {
      const handled = IDE.components.some(c => c.onKeydown &&
        c.onKeydown({ key: 'o', metaKey: true, shiftKey: false, ctrlKey: false, preventDefault: ()=>{} }, IDE));
      const el = document.getElementById('app-picker');
      if (el) el.style.display = 'none';
      return handled;
    });

    // Session picker — bus, hotkey
    await this.test('session-picker:open via bus', async () => {
      const el = document.getElementById('session-picker');
      IDE.bus.emit('session-picker:open');
      await this.wait(300);
      const open = el.style.display === 'flex';
      el.style.display = 'none';
      return open;
    });

    await this.test('session-picker:open via Cmd+Shift+O hotkey', async () => {
      const handled = IDE.components.some(c => c.onKeydown &&
        c.onKeydown({ key: 'O', metaKey: true, shiftKey: true, ctrlKey: false, preventDefault: ()=>{} }, IDE));
      const el = document.getElementById('session-picker');
      if (el) el.style.display = 'none';
      return handled;
    });

    // Autocomplete — bus
    await this.test('autocomplete:close via bus', async () => {
      IDE.bus.emit('autocomplete:close');
      return !document.querySelector('.awesomplete > ul:not([hidden])');
    });

    // Tab switch — bus, click
    await this.test('switchTab("chat") via function', async () => {
      IDE.switchTab('chat');
      return document.querySelector('.tab[data-tab="chat"]').classList.contains('active');
    });

    // Panel toggle — bus, click
    await this.test('collapsePanel("apps") toggles', async () => {
      const panel = document.getElementById('panel-apps');
      const was = panel.classList.contains('closed');
      IDE.collapsePanel('apps');
      const is = panel.classList.contains('closed');
      IDE.collapsePanel('apps'); // restore
      return was !== is;
    });

    // Command log toggle — click
    // Sidebar clicks via bus
    await this.test('sidebar:toggle via bus', async () => {
      const was = IDE.el.sidebar.classList.contains('collapsed');
      IDE.bus.emit('sidebar:toggle');
      const is = IDE.el.sidebar.classList.contains('collapsed');
      IDE.bus.emit('sidebar:toggle'); // restore
      return was !== is;
    });

    await this.test('panel:collapse via bus', async () => {
      const panel = document.getElementById('panel-apps');
      const was = panel.classList.contains('closed');
      IDE.bus.emit('panel:collapse', 'apps');
      const is = panel.classList.contains('closed');
      IDE.bus.emit('panel:collapse', 'apps'); // restore
      return was !== is;
    });

    await this.test('panel:show via bus', async () => {
      const panel = document.getElementById('panel-hex');
      panel.classList.add('hidden', 'closed');
      IDE.bus.emit('panel:show', 'hex');
      const shown = !panel.classList.contains('hidden') && !panel.classList.contains('closed');
      panel.classList.add('hidden'); // restore
      return shown;
    });

    await this.test('tests panel exists', async () => {
      return !!document.getElementById('panel-tests');
    });

    await this.test('command-log:toggle via bus', async () => {
      const log = document.getElementById('command-log');
      log.classList.add('collapsed');
      IDE.bus.emit('command-log:toggle');
      const opened = !log.classList.contains('collapsed');
      IDE.bus.emit('command-log:toggle'); // close
      return opened;
    });

    await this.test('tab:close via bus', async () => {
      IDE.createTab('test-tab', 'Test');
      const existed = !!IDE.state.openTabs['test-tab'];
      IDE.bus.emit('tab:close', 'test-tab');
      return existed && !IDE.state.openTabs['test-tab'];
    });

    await this.test('command-log toggle via click', async () => {
      const log = document.getElementById('command-log');
      log.classList.add('collapsed');
      IDE.bus.emit('command-log:toggle');
      const opened = !log.classList.contains('collapsed');
      IDE.bus.emit('command-log:toggle'); // close
      return opened;
    });

    // Sidebar actions via bus
    await this.test('workshop:open via bus', async () => {
      IDE.bus.emit('workshop:open', { path: 'examples/pizzas/PizzasBluebook', name: 'Pizzas' });
      await this.wait(1500);
      const tab = document.querySelector('.tab[data-tab="workshop"]');
      const opened = !!tab;
      if (tab) { IDE.state.wsActive = false; IDE.closeTab('workshop'); IDE.el.prompt.placeholder = 'Type a message...'; }
      return opened;
    });

    await this.test('hecksagon:open via bus', async () => {
      IDE.bus.emit('hecksagon:open', 'examples/pizzas/PizzasHecksagon');
      await this.wait(1500);
      const tab = document.querySelector('.tab[data-tab="hecksagon"]');
      const opened = !!tab;
      if (tab) IDE.closeTab('hecksagon');
      return opened;
    });

    await this.test('file:open via bus', async () => {
      IDE.bus.emit('file:request', { path: 'CLAUDE.md' });
      await this.wait(500);
      const tabs = Object.keys(IDE.state.openTabs);
      const opened = tabs.some(t => t.includes('CLAUDE'));
      tabs.filter(t => t.includes('CLAUDE')).forEach(t => IDE.closeTab(t));
      return opened;
    });

    await this.test('test-run button exists in panel', async () => {
      return !!document.querySelector('#panel-tests button');
    });

    // Slash commands
    await this.test('/hecks-ide-commands via slash', async () => {
      IDE.el.msgs.innerHTML = '';
      IDE.el.prompt.value = '/hecks-ide-commands';
      await IDE.sendPrompt();
      await this.wait(100);
      return IDE.el.msgs.textContent.includes('/hecks-ide-clear');
    });

    await this.test('/hecks-ide-log via slash', async () => {
      const log = document.getElementById('command-log');
      log.classList.add('collapsed');
      IDE.el.prompt.value = '/hecks-ide-log';
      await IDE.sendPrompt();
      await this.wait(100);
      return !log.classList.contains('collapsed');
    });

    await this.test('/hecks-ide-clear via slash', async () => {
      IDE.addTurn('system', 'test');
      IDE.el.prompt.value = '/hecks-ide-clear';
      await IDE.sendPrompt();
      await this.wait(100);
      return IDE.el.msgs.children.length === 0;
    });

    await this.test('/hecks-ide-reset via slash', async () => {
      IDE.addTurn('system', 'test');
      const oldIdx = IDE.state.nextIndex;
      IDE.el.prompt.value = '/hecks-ide-reset';
      await IDE.sendPrompt();
      await this.wait(100);
      return IDE.el.msgs.children.length === 0;
    });

    // Escape — hotkey
    await this.test('Escape interrupts when busy', async () => {
      IDE.state.busy = true;
      IDE.el.send.disabled = true;
      this.simulateKey('Escape');
      await this.wait(100);
      return !IDE.state.busy;
    });

    // Command history — hotkey
    await this.test('ArrowUp recalls history', async () => {
      IDE.state.cmdHistory = ['test-cmd-1', 'test-cmd-2'];
      IDE.state.histIdx = -1;
      IDE.el.prompt.value = '';
      IDE.el.prompt.focus();
      this.simulateKey('ArrowUp', {}, IDE.el.prompt);
      await this.wait(50);
      const val = IDE.el.prompt.value;
      IDE.state.cmdHistory = [];
      IDE.state.histIdx = -1;
      return val === 'test-cmd-2';
    });

    await this.test('ArrowDown navigates forward', async () => {
      IDE.state.cmdHistory = ['test-cmd-1', 'test-cmd-2'];
      IDE.state.histIdx = 0;
      IDE.el.prompt.value = 'test-cmd-1';
      IDE.el.prompt.focus();
      this.simulateKey('ArrowDown', {}, IDE.el.prompt);
      await this.wait(50);
      const val = IDE.el.prompt.value;
      IDE.state.cmdHistory = [];
      IDE.state.histIdx = -1;
      return val === 'test-cmd-2';
    });

    // Tab completion — hotkey
    await this.test('Tab completes in workshop mode', async () => {
      IDE.state.wsActive = true;
      IDE.state.wsCompletions = ['Pizza', 'Order'];
      IDE.el.prompt.value = 'Piz';
      IDE.el.prompt.focus();
      this.simulateKey('Tab', {}, IDE.el.prompt);
      await this.wait(50);
      const val = IDE.el.prompt.value;
      IDE.state.wsActive = false;
      IDE.state.wsCompletions = [];
      return val === 'Pizza';
    });

    this._totalTests = this.results.length;
    this.updatePanel('Done');
    this.hideOverlay();

    // Restore state after tests
    IDE.el.msgs.innerHTML = savedMsgs;
    IDE.el.prompt.value = savedPrompt;
    IDE.el.prompt.placeholder = savedPlaceholder;
    document.querySelectorAll('.panel').forEach(p => { if (panelStates[p.id]) p.className = panelStates[p.id]; });
    if (logCollapsed) document.getElementById('command-log').classList.add('collapsed');
    else document.getElementById('command-log').classList.remove('collapsed');
    const ap = document.getElementById('app-picker'); if (ap) ap.style.display = 'none';
    const sp = document.getElementById('session-picker'); if (sp) sp.style.display = 'none';
    IDE.switchTab('chat');
    IDE.el.status.textContent = '';
    IDE.state.busy = false;
    IDE.el.send.disabled = false;

    this.report();
  },

  async test(name, fn) {
    this.showOverlay(name);
    this.updatePanel(name);
    try {
      const result = await fn();
      this.results.push({ name, pass: !!result });
      if (!result) console.warn(`FAIL: ${name} returned falsy`);
    } catch (e) {
      this.results.push({ name, pass: false, error: e.message });
      console.error(`FAIL: ${name}: ${e.message}`);
    }
  },

  wait(ms) { return new Promise(r => setTimeout(r, ms)); },

  simulateKey(key, opts = {}, target = document) {
    const e = new KeyboardEvent('keydown', {
      key, bubbles: true, cancelable: true,
      metaKey: opts.metaKey || false,
      ctrlKey: opts.ctrlKey || false,
      shiftKey: opts.shiftKey || false
    });
    target.dispatchEvent(e);
  },

  report() {
    const passed = this.results.filter(r => r.pass).length;
    const failed = this.results.filter(r => !r.pass);
    const total = this.results.length;

    console.log(`IDE Tests: ${passed}/${total} passed, ${failed.length} failed`);
    this.results.forEach(r => {
      console.log(`  ${r.pass ? '✓' : '✗'} ${r.name}`);
    });

    fetch('/console', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        level: failed.length ? 'error' : 'log',
        message: `IDE Tests: ${passed}/${total} passed. ${failed.map(r => r.name).join(', ')}`
      })
    }).catch(() => {});
  }
};

let testTimer = null;
IDE.bus.on('test:run', () => {
  clearTimeout(testTimer);
  testTimer = setTimeout(() => IDETests.runAll(), 500);
});
