/* ── Console streaming component ── */
IDE.register({
  init() {
    window.onerror = (msg, src, line, col) => {
      const errMsg = `${msg} at ${src}:${line}:${col}`;
      ide.bus.emit('console:error', errMsg);
      fetch('/console', { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ level: 'error', message: errMsg })
      }).catch(() => {});
    };
    ['error', 'warn', 'log'].forEach(level => {
      const orig = console[level];
      console[level] = function(...args) {
        orig.apply(console, args);
        const msg = args.map(a => typeof a === 'string' ? a : JSON.stringify(a)).join(' ');
        if (level === 'error') ide.bus.emit('console:error', msg.slice(0, 200));
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
        const r = await fetch('/screenshot', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ data }) });
        const j = await r.json().catch(() => null);
        if (j?.path) ide.bus.emit('screenshot:saved', j.path);
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
      return true;
    }
    return false;
  }
});
