/* ── IDE Test Harness — exercises all commands via all entry points ── */

const IDETests = {
  results: [],

  async runAll() {
    this.results = [];

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
    await this.test('command-log toggle via click', async () => {
      const log = document.getElementById('command-log');
      const toggle = document.getElementById('command-log-toggle');
      log.classList.add('collapsed');
      toggle.click();
      const opened = !log.classList.contains('collapsed');
      toggle.click(); // close
      return opened;
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

    this.report();
  },

  async test(name, fn) {
    try {
      const result = await fn();
      this.results.push({ name, pass: !!result });
      if (!result) console.warn(`FAIL: ${name} returned falsy`);
    } catch (e) {
      this.results.push({ name, pass: false, error: e.message });
      console.error(`FAIL: ${name}: ${e.message}`);
    }
    await this.wait(400); // pause between tests so you can see each one
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
