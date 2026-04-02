/* ── Hecks IDE Core — Registry, State, Boot ── */

const IDE = {
  el: {},
  state: {
    busy: false, nextIndex: 0, curEl: null, lastUserEl: null,
    toolCount: 0, wsActive: false, wsCompletions: [], wsAggAttrs: {},
    activeFileCtx: null, openTabs: {}, cmdHistory: [], histIdx: -1
  },
  components: [],

  register(component) { this.components.push(component); },

  boot() {
    this.el = {
      msgs: document.getElementById('messages'),
      prompt: document.getElementById('prompt'),
      send: document.getElementById('send'),
      status: document.getElementById('status'),
      escHint: document.getElementById('esc-hint'),
      sidebar: document.getElementById('sidebar'),
      tabBar: document.getElementById('tab-bar'),
      thinkingBar: document.getElementById('thinking-bar'),
      toolLog: document.getElementById('tool-log'),
      toolCount: document.getElementById('tool-count'),
      chatScroller: document.getElementById('tab-chat'),
      eventsSidebar: document.getElementById('events-sidebar'),
      eventList: document.getElementById('event-list')
    };
    // Capture phase — fires before Awesomplete's handler
    document.addEventListener('keydown', e => {
      if (e.target === this.el.prompt) this.onKeydown(e);
    }, true);
    this.el.prompt.addEventListener('input', () => this.onInput());
    this.el.sidebar.addEventListener('click', e => {
      const link = e.target.closest('.ctx-link, .book-app-name');
      if (link) {
        this.el.sidebar.querySelectorAll('.active').forEach(a => a.classList.remove('active'));
        link.classList.add('active');
      }
    });
    this.components.forEach(c => { if (c.init) c.init(this); });
    setInterval(() => this.poll(), 250);
  },

  onKeydown(e) {
    for (const c of this.components) {
      if (c.onKeydown && c.onKeydown(e, this)) return;
    }
  },

  onInput() {
    const val = this.el.prompt.value.trim().toLowerCase();
    for (const c of this.components) {
      if (c.onInput && c.onInput(val, this)) return;
    }
  },

  esc(s) { return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); },

  addTurn(role, content) {
    const labels = { user: 'You', assistant: 'Claude', system: 'System' };
    const d = document.createElement('div');
    d.className = `turn turn-${role}`;
    d.innerHTML = `<div class="turn-label">${labels[role] || role}</div><div class="turn-body"><pre>${this.esc(content)}</pre></div>`;
    this.el.msgs.appendChild(d);
    this.el.chatScroller.scrollTo({ top: this.el.chatScroller.scrollHeight, behavior: 'smooth' });
    return d;
  },

  setBusy(busy) {
    this.state.busy = busy;
    this.el.send.disabled = busy;
    this.el.escHint.classList.toggle('hidden', !busy);
    this.el.thinkingBar.classList.toggle('active', busy);
    if (!busy) {
      if (this.state.lastUserEl) this.state.lastUserEl.classList.remove('thinking');
      this.el.status.textContent = '';
      this.state.curEl = null;
      this.el.prompt.focus();
    }
    this.bus.emit(busy ? 'prompt:send' : 'prompt:done');
  },

  bus: {
    _subs: {},
    on(evt, fn) { (this._subs[evt] ||= []).push(fn); },
    emit(evt, data) { (this._subs[evt] || []).forEach(fn => fn(data)); }
  },

  switchTab(id) {
    document.querySelectorAll('.tab').forEach(t => t.classList.toggle('active', t.dataset.tab === id));
    document.querySelectorAll('.tab-content').forEach(c => c.classList.toggle('active', c.id === 'tab-' + id));
    const tab = this.state.openTabs[id];
    this.state.activeFileCtx = (tab && id !== 'chat') ? tab.path : null;
    if (id === 'chat') this.el.prompt.focus();
    this.bus.emit('tab:switch', id);
  },

  createTab(id, label, html) {
    if (this.state.openTabs[id]) this.closeTab(id);
    const tab = document.createElement('div');
    tab.className = 'tab'; tab.dataset.tab = id;
    tab.innerHTML = `<span class="tab-label">${this.esc(label)}</span><span class="tab-close" onclick="event.stopPropagation();IDE.closeTab('${id}')">&#215;</span>`;
    tab.onclick = () => this.switchTab(id);
    this.el.tabBar.appendChild(tab);
    const content = document.createElement('div');
    content.className = 'tab-content'; content.id = 'tab-' + id;
    content.innerHTML = html || '';
    document.querySelector('.main').insertBefore(content, this.el.thinkingBar);
    this.state.openTabs[id] = { tab, content };
    return content;
  },

  closeTab(id) {
    const t = this.state.openTabs[id]; if (!t) return;
    t.tab.remove(); t.content.remove(); delete this.state.openTabs[id];
    this.switchTab('chat');
  },

  // panels.js provides: collapsePanel, toggleDotPanel, showPanel, syncDot, toggleSidebar

  addToolCall(name, input) {
    if (this.state.toolCount === 0) this.el.toolLog.innerHTML = '';
    this.state.toolCount++;
    this.el.toolCount.textContent = this.state.toolCount;
    const d = document.createElement('div');
    d.className = 'tool-entry';
    const s = typeof input === 'string' ? input : JSON.stringify(input);
    d.innerHTML = `<span class="tool-name">${this.esc(name)}</span><div class="tool-input">${this.esc(s.slice(0, 200))}</div>`;
    this.el.toolLog.appendChild(d);
  },

  async poll() {
    try {
      const r = await fetch(`/events?after=${this.state.nextIndex}`);
      const d = await r.json();
      d.events.forEach(raw => this.handleEvent(raw));
      this.state.nextIndex = d.next_index;
    } catch (e) {}
  },

  handleEvent(raw) {
    try {
      const e = JSON.parse(raw);
      if (e.type === 'assistant' && e.message?.content) {
        e.message.content.forEach(c => {
          if (c.type === 'text') {
            if (!this.state.curEl) this.state.curEl = this.addTurn('assistant', '');
            this.state.curEl.querySelector('pre').textContent += c.text;
            this.el.chatScroller.scrollTo({ top: this.el.chatScroller.scrollHeight, behavior: 'smooth' });
          }
          if (c.type === 'tool_use') this.addToolCall(c.name, c.input);
        });
      } else if (e.type === 'system' && e.subtype === 'init' && e.session_id) {
        localStorage.setItem('hecks-ide-session', e.session_id);
      } else if (e.type === 'result' && (e.subtype === 'success' || e.subtype === 'done')) {
        this.setBusy(false);
      } else if (e.type === 'error') {
        this.addTurn('system', e.message || 'Unknown error'); this.setBusy(false);
      } else if (e.type === 'bus') {
        this.bus.emit(e.event, e.data);
      } else if (e.type === 'reload') {
        this.state.nextIndex = 0; location.reload();
      }
    } catch (err) {}
  },

  async sendPrompt() {
    const text = this.el.prompt.value.trim();
    if (!text || this.state.busy) return;
    this.el.prompt.value = '';
    if (!text.startsWith('/')) this.state.cmdHistory.push(text);
    this.state.histIdx = -1;

    if (text.startsWith('/')) {
      for (const c of this.components) { if (c.handleSlash && c.handleSlash(text, this)) return; }
    }
    if (this.state.wsActive && document.querySelector('.tab[data-tab="workshop"].active')) {
      for (const c of this.components) { if (c.handleWorkshop && c.handleWorkshop(text, this)) return; }
    }

    this.switchTab('chat');
    this.state.lastUserEl = this.addTurn('user', text);
    this.state.lastUserEl.classList.add('thinking');
    this.state.curEl = null;
    this.state.toolCount = 0;
    this.el.toolCount.textContent = '0';
    this.el.toolLog.innerHTML = '<div class="tool-empty">No tool calls yet.</div>';
    this.setBusy(true);
    const body = { prompt: text };
    if (this.state.activeFileCtx) body.file_context = this.state.activeFileCtx;
    await fetch('/prompt', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  }
};

/* Global aliases for onclick handlers in HTML */
var switchTab = id => IDE.switchTab(id);
var sendPrompt = () => IDE.sendPrompt();
