/* ── Panel management — collapse, toggle, sync dots ── */

IDE.collapsePanel = function(name) {
  const el = document.getElementById('panel-' + name);
  el.classList.toggle('closed');
  IDE.syncDot(name);
};

IDE.toggleDotPanel = function(name) {
  IDE.collapsePanel(name);
};

IDE.showPanel = function(name) {
  const el = document.getElementById('panel-' + name);
  el.classList.remove('hidden', 'closed');
  IDE.syncDot(name);
};

IDE.syncDot = function(name) {
  const el = document.getElementById('panel-' + name);
  const dot = document.querySelector('.panel-dot-' + name);
  if (dot) dot.classList.toggle('inactive', el.classList.contains('closed'));
};

IDE.toggleSidebar = function() {
  IDE.el.sidebar.classList.toggle('collapsed');
};

/* Global aliases for onclick handlers */
var collapsePanel = n => IDE.collapsePanel(n);
var toggleDotPanel = n => IDE.toggleDotPanel(n);
var toggleSidebar = () => IDE.toggleSidebar();
