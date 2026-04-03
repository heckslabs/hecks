/* ── Panel management — all actions go through bus ── */

IDE.collapsePanel = function(name) {
  IDE.bus.emit('panel:collapse', name);
};

IDE.toggleDotPanel = function(name) {
  IDE.bus.emit('panel:collapse', name);
};

IDE.showPanel = function(name) {
  IDE.bus.emit('panel:show', name);
};

IDE.toggleSidebar = function() {
  IDE.bus.emit('sidebar:toggle');
};

IDE.syncDot = function(name) {
  const el = document.getElementById('panel-' + name);
  const dot = document.querySelector('.panel-dot-' + name);
  if (dot) dot.classList.toggle('inactive', el.classList.contains('closed'));
};

/* Bus handlers */
IDE.register({
  init(ide) {
    ide.bus.on('panel:collapse', (name) => {
      const el = document.getElementById('panel-' + name);
      if (el) el.classList.toggle('closed');
      IDE.syncDot(name);
    });

    ide.bus.on('panel:show', (name) => {
      const el = document.getElementById('panel-' + name);
      if (el) el.classList.remove('hidden', 'closed');
      IDE.syncDot(name);
    });

    ide.bus.on('sidebar:toggle', () => {
      IDE.el.sidebar.classList.toggle('collapsed');
    });

    ide.bus.on('command-log:toggle', () => {
      IDE.bus.emit('panel:collapse', 'ide-log');
    });

    ide.bus.on('tab:close', (id) => {
      IDE.closeTab(id);
    });
  }
});

/* Global aliases for onclick handlers */
var collapsePanel = n => IDE.collapsePanel(n);
var toggleDotPanel = n => IDE.toggleDotPanel(n);
var toggleSidebar = () => IDE.toggleSidebar();
