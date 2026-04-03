/* ── Autocomplete component (Awesomplete) ── */
IDE.register({
  awes: null,

  init(ide) {
    this.ide = ide;
    this.awes = new Awesomplete(ide.el.prompt, {
      minChars: 1, maxItems: 30, autoFirst: false,
      filter: () => true, sort: false, list: [],
      item: (text, input) => {
        const li = document.createElement('li');
        if (text.value.startsWith('──')) {
          li.textContent = text.value;
          li.style.cssText = 'color:#7ee787;font-size:9px;padding:6px 12px 2px !important;pointer-events:none;text-transform:uppercase;letter-spacing:0.5px;';
          li.setAttribute('aria-disabled', 'true');
        } else {
          li.textContent = text.value;
        }
        return li;
      }
    });

    ide.bus.on('autocomplete:close', () => {
      this.awes.list = [];
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
        const items = this.buildCompletions(val, ide).filter(c => !c.startsWith('──'));
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
      const ideC = ['/apps', '/sessions', '/hecks-ide-clear', '/hecks-ide-reset', '/hecks-ide-commands', '/hecks-ide-log', '/hecks-ide-test'];
      const clC = ['/commit','/review','/help','/compact','/clear','/cost','/init',
        '/pr-comments','/release-notes','/security-review','/simplify'];
      const ideMatches = ideC.filter(c => c.startsWith(val));
      const clMatches = inWs ? [] : clC.filter(c => c.startsWith(val));
      const result = [];
      if (clMatches.length) { result.push('── Hecks ──', ...clMatches); }
      if (ideMatches.length) { result.push('── IDE ──', ...ideMatches); }
      return result;
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
