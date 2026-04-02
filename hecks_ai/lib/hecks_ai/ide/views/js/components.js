/* ── Console streaming component ── */
IDE.register({
  init() {
    window.onerror = (msg, src, line, col) => {
      fetch('/console', { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ level: 'error', message: `${msg} at ${src}:${line}:${col}` })
      }).catch(() => {});
    };
    ['error', 'warn', 'log'].forEach(level => {
      const orig = console[level];
      console[level] = function(...args) {
        orig.apply(console, args);
        const msg = args.map(a => typeof a === 'string' ? a : JSON.stringify(a)).join(' ');
        fetch('/console', { method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ level, message: msg.slice(0, 1000) })
        }).catch(() => {});
      };
    });
  }
});

/* ── Screenshots component ── */
IDE.register({
  init(ide) {
    const capture = async () => {
      try {
        const canvas = await html2canvas(document.body, { backgroundColor: '#0d1117', scale: 0.5, logging: false });
        const data = canvas.toDataURL('image/png').split(',')[1];
        fetch('/screenshot', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ data }) });
      } catch (e) {}
    };

    // Continuous 1s screenshots
    setInterval(capture, 1000);

    // Burst on operations — 3 rapid captures at 300ms to catch post-operation state
    let burstTimer = null, burstCount = 0;
    const burst = () => {
      clearInterval(burstTimer); burstCount = 0;
      burstTimer = setInterval(() => {
        capture();
        if (++burstCount >= 3) clearInterval(burstTimer);
      }, 300);
    };
    ['file:open','tab:switch','prompt:send','prompt:done'].forEach(e => ide.bus.on(e, burst));
  }
});

/* ── Autocomplete component (Awesomplete) ── */
IDE.register({
  awes: null,

  init(ide) {
    this.ide = ide;
    this.awes = new Awesomplete(ide.el.prompt, {
      minChars: 1, maxItems: 10, autoFirst: false,
      filter: () => true, list: []
    });

    // Subscribe to bus events
    ide.bus.on('autocomplete:close', () => {
      this.awes.close();
      document.querySelectorAll('.awesomplete > ul').forEach(ul => ul.setAttribute('hidden', ''));
    });

    ide.bus.on('autocomplete:update', (val) => {
      const items = this.buildCompletions(val, ide);
      if (!items.length) { this.awes.close(); return; }
      this.awes.list = items;
      this.awes.evaluate();
    });
  },

  onKeydown(e, ide) {
    if (e.key === 'Tab') {
      const val = ide.el.prompt.value.trim().toLowerCase();
      if (val) {
        e.preventDefault();
        const items = this.buildCompletions(val, ide);
        if (items.length) {
          ide.el.prompt.value = items[0];
          ide.bus.emit('autocomplete:close');
        }
      }
      return true;
    }
    return false;
  },

  onInput(val, ide) {
    if (!val) { ide.bus.emit('autocomplete:close'); return true; }
    const inWs = ide.state.wsActive && document.querySelector('.tab[data-tab="workshop"].active');
    if (!inWs && !val.startsWith('/')) { ide.bus.emit('autocomplete:close'); return true; }
    ide.bus.emit('autocomplete:update', val);
    return true;
  },

  buildCompletions(val, ide) {
    const s = ide.state;
    const inWs = s.wsActive && document.querySelector('.tab[data-tab="workshop"].active');

    if (val.startsWith('/')) {
      const ideC = ['/hecks-ide-clear', '/hecks-ide-reset'];
      const clC = ['/commit','/review','/help','/compact','/clear','/cost','/init',
        '/pr-comments','/release-notes','/security-review','/simplify'];
      return [...ideC.filter(c => c.startsWith(val)), ...(inWs ? [] : clC.filter(c => c.startsWith(val)))];
    }
    if (!s.wsActive) return [];

    const parenIdx = val.indexOf('('), dotIdx = val.indexOf('.');
    if (parenIdx > 0) {
      const target = val.slice(0, dotIdx > 0 ? dotIdx : parenIdx).trim();
      const lastArg = val.slice(parenIdx + 1).split(',').pop().trim();
      const attrs = s.wsAggAttrs[target] || [];
      const raw = ide.el.prompt.value.trim();
      const prefix = raw.slice(0, raw.length - lastArg.length);
      return attrs.filter(a => !lastArg || a.startsWith(lastArg)).map(a => prefix + a + ': ');
    }
    if (dotIdx > 0) {
      const target = ide.el.prompt.value.trim().slice(0, dotIdx);
      const partial = val.slice(dotIdx + 1);
      const methods = ['attr','command','query','value_object','entity','reference_to',
        'validation','invariant','lifecycle','specification','describe',
        'create','find','all','count','first','last','new'];
      return methods.filter(m => m.startsWith(partial)).map(m => target + '.' + m);
    }
    return s.wsCompletions.filter(c => c.toLowerCase().startsWith(val));
  }
});

/* ── Command history component ── */
IDE.register({
  init(ide) {
    // Restore from localStorage
    try {
      const saved = localStorage.getItem('hecks-ide-history');
      if (saved) ide.state.cmdHistory = JSON.parse(saved);
    } catch (e) {}

    // Persist on each prompt
    ide.bus.on('prompt:send', () => {
      try {
        // Keep last 100
        const hist = ide.state.cmdHistory.slice(-100);
        localStorage.setItem('hecks-ide-history', JSON.stringify(hist));
      } catch (e) {}
    });
  },

  onKeydown(e, ide) {
    const s = ide.state;
    const awesOpen = document.querySelector('.awesomplete > ul:not([hidden])');
    if (e.key === 'ArrowUp' && !awesOpen && s.cmdHistory.length) {
      e.preventDefault();
      if (s.histIdx < 0) s.histIdx = s.cmdHistory.length;
      s.histIdx = Math.max(s.histIdx - 1, 0);
      ide.el.prompt.value = s.cmdHistory[s.histIdx] || '';
      return true;
    }
    if (e.key === 'ArrowDown' && !awesOpen && s.histIdx >= 0) {
      e.preventDefault();
      s.histIdx = Math.min(s.histIdx + 1, s.cmdHistory.length);
      ide.el.prompt.value = s.histIdx < s.cmdHistory.length ? s.cmdHistory[s.histIdx] : '';
      return true;
    }
    return false;
  }
});

/* ── Enter/Escape key component ── */
IDE.register({
  onKeydown(e, ide) {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      e.stopImmediatePropagation();
      ide.bus.emit('autocomplete:close');
      ide.sendPrompt();
      return true;
    }
    if (e.key === 'Escape' && ide.state.busy) {
      fetch('/interrupt', { method: 'POST' });
      ide.setBusy(false);
      ide.el.status.textContent = 'interrupted';
      return true;
    }
    return false;
  }
});

/* ── Slash commands component ── */
IDE.register({
  handleSlash(text, ide) {
    const cmd = text.split(/\s/)[0];
    const commands = {
      '/hecks-ide-clear': () => { ide.el.msgs.innerHTML = ''; },
      '/hecks-ide-reset': () => { ide.el.msgs.innerHTML = ''; ide.state.nextIndex = 0; }
    };
    if (commands[cmd]) {
      commands[cmd]();
      ide.addTurn('system', `Ran ${cmd}`);
      return true;
    }
    return false;
  }
});
