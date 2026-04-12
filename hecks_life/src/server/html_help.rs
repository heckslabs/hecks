//! Help popup JS — contextual ? icon support
//!
//! Provides the showHelp() function that reads data-domain-*
//! attributes to build a context-aware help modal.
//!
//! Usage:
//!   let js = help_script();  // include in <script> block

/// Return the showHelp JS function body (already double-braced for format!)
pub fn help_script() -> &'static str {
    r#"  function showHelp(btn) {
    const agg = btn.closest('[data-domain-aggregate]');
    const cmd = btn.closest('[data-domain-command]');
    let title = '', body = '';
    if (cmd) {
      const name = cmd.getAttribute('data-domain-command');
      title = humanize(name);
      const desc = cmd.querySelector('p');
      const inputs = cmd.querySelectorAll('input');
      body = '<p class="mb-3">' + (desc ? desc.textContent : 'Execute this action') + '</p>';
      if (inputs.length) {
        body += '<p class="text-xs text-gray-400 mb-2">Required fields:</p><ul class="text-xs text-gray-300 list-disc pl-4">';
        inputs.forEach(i => body += '<li>' + humanize(i.name) + ' (' + (i.placeholder || 'text') + ')</li>');
        body += '</ul>';
      }
    } else if (agg) {
      const name = agg.getAttribute('data-domain-aggregate');
      title = humanize(name);
      const desc = agg.querySelector('p');
      body = '<p class="mb-3">' + (desc ? desc.textContent : 'This module manages ' + humanize(name).toLowerCase()) + '</p>';
      const cmds = agg.querySelectorAll('[data-domain-command]');
      const rows = agg.querySelectorAll('tbody tr');
      body += '<p class="text-xs text-gray-400">Available actions: ' + cmds.length + '</p>';
      body += '<p class="text-xs text-gray-400">Current records: ' + rows.length + '</p>';
    }
    const modal = document.createElement('div');
    modal.className = 'fixed inset-0 bg-black/60 flex items-center justify-center z-50';
    modal.onclick = function(e) { if (e.target === modal) modal.remove(); };
    modal.innerHTML = '<div class="bg-surface-2 rounded-xl p-6 max-w-md w-full mx-4 border border-surface-3">' +
      '<div class="flex items-center justify-between mb-4"><h3 class="text-lg font-bold text-brand">ℹ️ ' + title + '</h3>' +
      '<button onclick="this.closest(\'div.fixed\').remove()" class="text-gray-500 hover:text-white">✕</button></div>' +
      body +
      '<div class="mt-4 p-3 rounded bg-surface-3 border border-surface-4">' +
      '<p class="text-xs text-gray-400 mb-2">Need more help?</p>' +
      '<input placeholder="Ask about ' + title + '..." class="w-full bg-surface-0 border border-surface-4 rounded px-3 py-1.5 text-sm text-gray-100 focus:border-brand focus:outline-none">' +
      '</div></div>';
    document.body.appendChild(modal);
  }"#
}
