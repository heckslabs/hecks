/* ── Hecks IDE Core — Registry, State, Boot ── */

const IDE = {
  el: {},
  state: {
    busy: false, paused: false, nextIndex: 0, curEl: null, lastUserEl: null,
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
    // Global hotkeys (Cmd+O, Cmd+Shift+O, Escape) fire from anywhere
    // Input-specific keys (Enter, Tab, arrows) only from prompt
    document.addEventListener('keydown', e => {
      const isGlobal = (e.metaKey || e.ctrlKey) || e.key === 'Escape';
      if (isGlobal || e.target === this.el.prompt) this.onKeydown(e);
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

  // Tailwind class maps for dynamically created elements
  tw: {
    turn: 'mb-5',
    turnLabel: 'font-mono text-[11px] font-semibold uppercase tracking-wider mb-1.5',
    turnLabelColor: { user: 'text-accent-blue', assistant: 'text-accent-green', system: 'text-fg-dim' },
    turnBody: 'font-mono text-sm leading-relaxed py-2.5 px-3.5 rounded-lg',
    turnBodyStyle: { user: 'bg-bg-user border-l-[3px] border-accent-blue', assistant: 'bg-bg-msg', system: 'bg-transparent text-fg-dim text-xs' },
    tab: 'px-4 py-2 cursor-pointer text-fg-dim border-r border-border whitespace-nowrap flex items-center gap-1.5 select-none tab',
    tabClose: 'text-sm text-fg-dim cursor-pointer leading-none hover:text-accent-red',
    tabContent: 'flex-1 overflow-y-auto scroll-smooth tab-content',
    toolEntry: 'py-1.5 px-2 mb-1 rounded bg-[#1a1e2a] text-[11px] leading-snug',
    toolName: 'text-accent-yellow font-semibold',
    toolInput: 'text-fg-dim mt-0.5 max-h-10 overflow-hidden whitespace-nowrap text-ellipsis',
    eventItem: 'py-1.5 px-2 mb-1 rounded bg-bg-msg text-[11px] leading-snug',
    eventType: 'text-accent-green font-semibold',
    eventAttrs: 'text-fg-dim mt-0.5',
  },

  addTurn(role, content) {
    const labels = { user: 'You', assistant: 'Claude', system: 'System' };
    const d = document.createElement('div');
    d.className = `${this.tw.turn} turn turn-${role}`;
    const lc = this.tw.turnLabelColor[role] || 'text-fg-dim';
    const bc = this.tw.turnBodyStyle[role] || 'bg-bg-msg';
    d.innerHTML = `<div class="${this.tw.turnLabel} ${lc}">${labels[role] || role}</div><div class="${this.tw.turnBody} ${bc} turn-body"><pre class="whitespace-pre-wrap break-words m-0">${this.esc(content)}</pre></div>`;
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
    tab.className = this.tw.tab; tab.dataset.tab = id;
    tab.innerHTML = `<span class="tab-label">${this.esc(label)}</span><span class="${this.tw.tabClose}" onclick="event.stopPropagation();IDE.closeTab('${id}')">&#215;</span>`;
    tab.onclick = () => this.switchTab(id);
    this.el.tabBar.appendChild(tab);
    const content = document.createElement('div');
    content.className = this.tw.tabContent; content.id = 'tab-' + id;
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

  addToolCall(name, input, toolUseId) {
    if (this.state.toolCount === 0) this.el.toolLog.innerHTML = '';
    this.state.toolCount++;
    this.el.toolCount.textContent = this.state.toolCount;
    const d = document.createElement('div');
    d.className = this.tw.toolEntry;
    d.style.cursor = 'pointer';
    if (toolUseId) d.dataset.toolId = toolUseId;
    const s = typeof input === 'string' ? input : JSON.stringify(input);
    d.innerHTML = `<span class="${this.tw.toolName}">${this.esc(name)}</span><div class="${this.tw.toolInput}">${this.esc(s.slice(0, 200))}</div>`;
    d.addEventListener('click', () => this.showToolPopup(name, s, d));
    this.el.toolLog.appendChild(d);
  },

  showToolPopup(name, input, entry) {
    const existing = document.getElementById('tool-popup');
    if (existing) existing.remove();
    const resultPre = entry.querySelector('pre');
    const result = resultPre ? resultPre.textContent : '';
    const overlay = document.createElement('div');
    overlay.id = 'tool-popup';
    overlay.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,0.6);z-index:60;display:flex;align-items:center;justify-content:center;';
    const box = document.createElement('div');
    box.style.cssText = 'background:#161b22;border:1px solid #30363d;border-radius:8px;width:700px;max-height:80vh;overflow-y:auto;padding:16px;font-family:SF Mono,Fira Code,Menlo,monospace;font-size:12px;';
    box.innerHTML = `<div style="display:flex;justify-content:space-between;margin-bottom:12px;">` +
      `<span style="color:#7ee787;font-weight:bold;">${this.esc(name)}</span>` +
      `<span style="color:#8b949e;cursor:pointer;" id="tool-popup-close">&#215;</span></div>` +
      `<div style="color:#58a6ff;font-size:10px;margin-bottom:8px;">INPUT</div>` +
      `<pre style="margin:0 0 12px;white-space:pre-wrap;color:#c9d1d9;">${this.esc(input)}</pre>` +
      (result ? `<div style="color:#58a6ff;font-size:10px;margin-bottom:8px;">OUTPUT</div>` +
        `<pre style="margin:0;white-space:pre-wrap;color:#8b949e;">${this.esc(result)}</pre>` : '');
    overlay.appendChild(box);
    document.body.appendChild(overlay);
    overlay.addEventListener('click', e => { if (e.target === overlay) overlay.remove(); });
    box.querySelector('#tool-popup-close').addEventListener('click', () => overlay.remove());
    document.addEventListener('keydown', function esc(e) { if (e.key === 'Escape') { overlay.remove(); document.removeEventListener('keydown', esc); } });
  },

  async poll() {
    if (this.state.paused) return;
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
        const texts = e.message.content.filter(c => c.type === 'text').map(c => c.text).join('');
        if (texts) {
          if (!this.state.curEl) this.state.curEl = this.addTurn('assistant', '');
          this.state.curEl.querySelector('pre').textContent = texts;
          this.el.chatScroller.scrollTo({ top: this.el.chatScroller.scrollHeight, behavior: 'smooth' });
        }
        e.message.content.forEach(c => {
          if (c.type === 'tool_use') this.addToolCall(c.name, c.input, c.id);
        });
        if (e.message.stop_reason === 'end_turn' || e.message.stop_reason === 'stop_sequence') {
          this.state.curEl = null;
        }
      } else if (e.type === 'system' && e.subtype === 'init' && e.session_id) {
        localStorage.setItem('hecks-ide-session', e.session_id);
      } else if (e.type === 'result' && (e.subtype === 'success' || e.subtype === 'done')) {
        this.setBusy(false);
      } else if (e.type === 'error') {
        this.addTurn('system', e.message || 'Unknown error'); this.setBusy(false);
      } else if (e.type === 'user_echo') {
        this.state.curEl = null;
        const msg = e.message;
        const text = typeof msg === 'string' ? msg
          : typeof msg?.content === 'string' ? msg.content
          : Array.isArray(msg?.content) ? msg.content.map(c => c.text).filter(Boolean).join('') : null;
        if (text) {
          const clean = text.split('\n\n[IDE').shift().trim();
          if (clean && clean !== this.state.lastPromptText) this.addTurn('user', clean);
          this.state.lastPromptText = null;
        }
      } else if (e.type === 'tool_result') {
        const out = (e.output || '').slice(0, 2000);
        if (out && e.tool_use_id) {
          const entry = this.el.toolLog.querySelector(`[data-tool-id="${e.tool_use_id}"]`);
          if (entry) {
            const pre = document.createElement('pre');
            pre.style.cssText = 'margin:4px 0 0;white-space:pre-wrap;color:#8b949e;font-size:10px;max-height:150px;overflow-y:auto;';
            pre.textContent = out;
            entry.appendChild(pre);
          }
        }
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
    this.state.paused = false;
    this.state.lastPromptText = text;
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
