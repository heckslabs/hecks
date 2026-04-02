/* ── IDE Test Harness — run via /test endpoint ── */
/* Tests all bus commands and verifies DOM state */

const IDETests = {
  results: [],

  async runAll() {
    this.results = [];
    await this.testBusEmit();
    await this.testAppPicker();
    await this.testSessionPicker();
    await this.testAutocompleteClose();
    await this.testTabSwitch();
    await this.testSlashCommand();
    await this.testPanelToggle();
    await this.testCommandLogToggle();
    await this.testGlobalHotkeys();
    this.report();
  },

  assert(name, condition) {
    this.results.push({ name, pass: !!condition });
    if (!condition) console.error(`FAIL: ${name}`);
  },

  async testBusEmit() {
    let received = false;
    IDE.bus.on('test:ping', () => { received = true; });
    IDE.bus.emit('test:ping');
    this.assert('bus.emit delivers to subscribers', received);
  },

  async testAppPicker() {
    const picker = document.getElementById('app-picker');
    this.assert('app-picker exists in DOM', !!picker);

    IDE.bus.emit('app-picker:open');
    await new Promise(r => setTimeout(r, 500));
    this.assert('app-picker:open shows overlay', picker.style.display === 'flex');

    // Close it
    picker.style.display = 'none';
  },

  async testSessionPicker() {
    const picker = document.getElementById('session-picker');
    this.assert('session-picker exists in DOM', !!picker);

    IDE.bus.emit('session-picker:open');
    await new Promise(r => setTimeout(r, 500));
    this.assert('session-picker:open shows overlay', picker.style.display === 'flex');

    // Check it has session entries
    const entries = picker.querySelectorAll('[data-idx]');
    this.assert('session-picker has entries', entries.length > 0);

    // Close it
    picker.style.display = 'none';
  },

  async testAutocompleteClose() {
    IDE.bus.emit('autocomplete:close');
    const open = document.querySelector('.awesomplete > ul:not([hidden])');
    this.assert('autocomplete:close hides dropdown', !open);
  },

  async testTabSwitch() {
    const chatTab = document.querySelector('.tab[data-tab="chat"]');
    this.assert('chat tab exists', !!chatTab);

    IDE.switchTab('chat');
    this.assert('switchTab("chat") activates chat', chatTab.classList.contains('active'));
  },

  async testSlashCommand() {
    const msgsBefore = IDE.el.msgs.children.length;
    IDE.el.prompt.value = '/hecks-ide-clear';
    IDE.sendPrompt();
    await new Promise(r => setTimeout(r, 100));
    this.assert('/hecks-ide-clear clears messages', IDE.el.msgs.children.length <= 1);
  },

  async testPanelToggle() {
    const panel = document.getElementById('panel-apps');
    this.assert('apps panel exists', !!panel);

    const wasClosed = panel.classList.contains('closed');
    IDE.collapsePanel('apps');
    const isClosed = panel.classList.contains('closed');
    this.assert('collapsePanel toggles closed state', wasClosed !== isClosed);

    // Toggle back
    IDE.collapsePanel('apps');
  },

  async testCommandLogToggle() {
    const log = document.getElementById('command-log');
    const toggle = document.getElementById('command-log-toggle');
    this.assert('command-log exists', !!log);
    this.assert('command-log-toggle exists', !!toggle);
    this.assert('command-log starts collapsed', log.classList.contains('collapsed'));

    // Simulate click
    toggle.click();
    this.assert('toggle click opens log', !log.classList.contains('collapsed'));

    // Close it back
    toggle.click();
    this.assert('toggle click closes log', log.classList.contains('collapsed'));
  },

  async testGlobalHotkeys() {
    // Test that hotkey components are registered
    const hasAppPicker = IDE.components.some(c => c.onKeydown &&
      c.onKeydown({ key: 'o', metaKey: true, shiftKey: false, ctrlKey: false, preventDefault: ()=>{} }, IDE));
    this.assert('Cmd+O handled by app picker', hasAppPicker);

    // Close the picker it opened
    const ap = document.getElementById('app-picker');
    if (ap) ap.style.display = 'none';

    const hasSessionPicker = IDE.components.some(c => c.onKeydown &&
      c.onKeydown({ key: 'O', metaKey: true, shiftKey: true, ctrlKey: false, preventDefault: ()=>{} }, IDE));
    this.assert('Cmd+Shift+O handled by session picker', hasSessionPicker);

    const sp = document.getElementById('session-picker');
    if (sp) sp.style.display = 'none';
  },

  report() {
    const passed = this.results.filter(r => r.pass).length;
    const failed = this.results.filter(r => !r.pass).length;
    const total = this.results.length;

    console.log(`IDE Tests: ${passed}/${total} passed, ${failed} failed`);
    this.results.forEach(r => {
      console.log(`  ${r.pass ? '✓' : '✗'} ${r.name}`);
    });

    // Send results to server
    fetch('/console', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        level: failed ? 'error' : 'log',
        message: `IDE Tests: ${passed}/${total} passed. ${this.results.filter(r=>!r.pass).map(r=>r.name).join(', ')}`
      })
    }).catch(() => {});
  }
};

/* Trigger tests via bus */
IDE.bus.on('test:run', () => IDETests.runAll());
