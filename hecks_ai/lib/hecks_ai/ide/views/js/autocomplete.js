/* ── Autocomplete component (Awesomplete) ── */
IDE.register({
  awes: null,

  init(ide) {
    this.ide = ide;
    this.awes = new Awesomplete(ide.el.prompt, {
      minChars: 1, maxItems: 10, autoFirst: false,
      filter: () => true, list: []
    });

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
