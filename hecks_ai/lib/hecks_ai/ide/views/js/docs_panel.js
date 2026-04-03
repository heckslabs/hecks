/* ── Contextual documentation panel ── */
IDE.register({
  init(ide) {
    this.ide = ide;
    this.docs = [];
    this.loaded = false;

    // Update docs when context changes
    ide.bus.on('tab:switch', (id) => this.updateForContext(id));
    ide.bus.on('prompt:done', () => this.updateForContext(this.currentContext()));

    // Initial load
    setTimeout(() => this.updateForContext('chat'), 500);
  },

  async loadDocs() {
    if (this.loaded) return;
    try {
      const r = await fetch('/docs');
      const d = await r.json();
      this.docs = (d.docs || []).map(doc => ({
        path: doc.path,
        label: doc.label,
        keywords: doc.label.toLowerCase().split(/[\s_-]+/)
      }));
      this.loaded = true;
    } catch (e) {
      // Fallback to context endpoint
      try {
        const r2 = await fetch('/context');
        const d2 = await r2.json();
        this.docs = (d2.docs || []).map(doc => ({
          path: doc.path,
          label: doc.label,
          keywords: doc.label.toLowerCase().split(/[\s_-]+/)
        }));
        this.loaded = true;
      } catch (e2) {}
    }
  },

  currentContext() {
    const active = document.querySelector('.tab.active');
    return active ? active.dataset.tab : 'chat';
  },

  async updateForContext(tabId) {
    await this.loadDocs();
    const panel = document.getElementById('docs-body');
    if (!panel) return;

    const keywords = this.contextKeywords(tabId);
    const matches = this.findRelevant(keywords);

    if (!matches.length) {
      panel.innerHTML = '<span style="color:var(--fg-dim);font-style:italic">No contextual docs.</span>';
      return;
    }

    panel.innerHTML = matches.map(doc =>
      `<a class="block text-fg py-px whitespace-nowrap overflow-hidden text-ellipsis cursor-pointer hover:text-accent-blue" onclick="openFile('${doc.path}', {doc:true})">${IDE.esc(doc.label)}</a>`
    ).join('');
  },

  contextKeywords(tabId) {
    if (tabId === 'workshop') {
      return ['aggregate', 'command', 'query', 'value', 'entity', 'reference',
              'validation', 'invariant', 'lifecycle', 'specification', 'dsl',
              'workshop', 'computed', 'scope', 'policy'];
    }
    if (tabId === 'hecksagon') {
      return ['hecksagon', 'capability', 'extension', 'gate', 'adapter',
              'tenancy', 'pii', 'audit', 'auth', 'crud'];
    }
    if (tabId === 'chat') {
      return ['cli', 'build', 'serve', 'context', 'architecture', 'getting'];
    }
    // File tab — use filename keywords
    const tab = IDE.state.openTabs[tabId];
    if (tab?.path) {
      return tab.path.toLowerCase().replace(/[^a-z]/g, ' ').split(/\s+/).filter(w => w.length > 2);
    }
    return [];
  },

  findRelevant(keywords) {
    if (!keywords.length) return this.docs.slice(0, 8);
    return this.docs
      .map(doc => {
        const score = keywords.reduce((s, kw) =>
          s + (doc.keywords.some(dk => dk.includes(kw) || kw.includes(dk)) ? 1 : 0), 0);
        return { ...doc, score };
      })
      .filter(d => d.score > 0)
      .sort((a, b) => b.score - a.score)
      .slice(0, 10);
  }
});
