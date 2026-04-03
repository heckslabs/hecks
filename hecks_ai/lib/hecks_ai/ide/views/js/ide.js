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
    this.el.prompt.addEventListener('input', () => {
      this.onInput();
      this.el.prompt.style.height = 'auto';
      this.el.prompt.style.height = Math.min(this.el.prompt.scrollHeight, 72) + 'px';
      this.el.prompt.style.color = this.el.prompt.value.startsWith('!') ? '#f85149' : '';
    });
    this.el.sidebar.addEventListener('click', e => {
      const link = e.target.closest('.ctx-link, .book-app-name');
      if (link) {
        this.el.sidebar.querySelectorAll('.active').forEach(a => a.classList.remove('active'));
        link.classList.add('active');
      }
    });
    this.components.forEach(c => { if (c.init) c.init(this); });

    // Restore cached chat and scroll position
    const cached = localStorage.getItem('hecks-ide-chat');
    if (cached) {
      this.el.msgs.innerHTML = cached;
      const scroll = parseInt(localStorage.getItem('hecks-ide-scroll') || '0', 10);
      setTimeout(() => this.el.chatScroller.scrollTop = scroll, 100);
    }

    setInterval(() => this.poll(), 250);
    setInterval(() => {
      localStorage.setItem('hecks-ide-chat', this.el.msgs.innerHTML);
      localStorage.setItem('hecks-ide-scroll', this.el.chatScroller.scrollTop);
    }, 2000);

    // Image drop — anywhere on the page
    document.addEventListener('dragover', e => { e.preventDefault(); e.dataTransfer.dropEffect = 'copy'; });
    document.addEventListener('drop', e => {
      e.preventDefault();
      const file = [...(e.dataTransfer.files || [])].find(f => f.type.startsWith('image/'));
      if (!file) return;
      const reader = new FileReader();
      reader.onload = async () => {
        const b64 = reader.result.split(',')[1];
        try {
          const r = await fetch('/screenshot', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ data: b64 }) });
          const j = await r.json();
          if (j?.path) {
            const el = this.addTurn('system', '');
            el.querySelector('.turn-body').innerHTML =
              `<div style="font-size:11px;color:#8b949e;margin-bottom:4px">Image attached: ${this.esc(j.path)}</div>` +
              `<img src="data:image/png;base64,${b64}" style="max-width:100%;max-height:200px;border-radius:6px;border:1px solid #30363d">`;
            this.bus.emit('screenshot:saved', j.path);
          }
        } catch (err) { this.addTurn('system', 'Failed to upload image'); }
      };
      reader.readAsDataURL(file);
    });
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

  toolSummary(name, input) {
    if (input.file_path) return input.file_path;
    if (input.command) return input.command.slice(0, 80);
    if (input.pattern) return input.pattern;
    if (input.path) return input.path;
    if (input.prompt) return input.prompt.slice(0, 60);
    return JSON.stringify(input).slice(0, 80);
  },

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
        const msgId = e.message.id;
        if (msgId && msgId !== this.state.lastMsgId) {
          this.state.curEl = null;
          this.state.lastMsgId = msgId;
        }
        const texts = e.message.content.filter(c => c.type === 'text').map(c => c.text).join('').trim();
        if (texts && texts !== 'No response requested.') {
          if (!this.state.curEl) this.state.curEl = this.addTurn('assistant', '');
          const body = this.state.curEl.querySelector('.turn-body');
          body.innerHTML = renderMd(texts);
          this.el.chatScroller.scrollTo({ top: this.el.chatScroller.scrollHeight, behavior: 'smooth' });
        }
        e.message.content.forEach(c => {
          if (c.type === 'tool_use') {
            this.addToolCall(c.name, c.input, c.id);
            const summary = this.toolSummary(c.name, c.input);
            const d = document.createElement('div');
            d.className = 'text-[11px] font-mono text-fg-dim my-1 rounded bg-bg-msg cursor-pointer hover:bg-bg-user';
            const header = `<div class="flex items-center gap-2 py-1 px-3"><span class="text-accent-yellow tool-chevron" style="font-size:8px">&#9654;</span> <span class="text-accent-yellow">${this.esc(c.name)}</span> <span class="truncate opacity-70 tool-summary">${this.esc(summary)}</span></div>`;
            const detail = `<pre class="hidden px-3 pb-2 whitespace-pre-wrap text-fg-dim opacity-70 text-[10px]" style="max-height:200px;overflow-y:auto">${this.esc(JSON.stringify(c.input, null, 2))}</pre>`;
            d.innerHTML = header + detail;
            d.querySelector('.flex').onclick = () => {
              const pre = d.querySelector('pre');
              const chev = d.querySelector('.tool-chevron');
              pre.classList.toggle('hidden');
              chev.innerHTML = pre.classList.contains('hidden') ? '&#9654;' : '&#9660;';
            };
            this.el.msgs.appendChild(d);
            this.el.chatScroller.scrollTo({ top: this.el.chatScroller.scrollHeight, behavior: 'smooth' });
          }
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
          if (!clean || clean === this.state.lastPromptText) { /* skip */ }
          else if (/^\[Request interrupted/.test(clean)) { this.state.curEl = null; this.addTurn('system', 'Interrupted — what would you like to do?'); }
          else if (/^\[Image|^<system-reminder|^<local-command|^<command-/.test(clean)) { /* skip internal */ }
          else this.addTurn('user', clean);
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
    if (!text) return;
    this.el.prompt.value = '';
    if (!text.startsWith('/')) this.state.cmdHistory.push(text);
    this.state.histIdx = -1;

    if (text.startsWith('/') || text.startsWith('!')) {
      for (const c of this.components) { if (c.handleSlash && c.handleSlash(text, this)) return; }
    }
    if (this.state.wsActive) {
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
