//! Wizard modal JS — creation wizard popup and space bar fix
//!
//! Provides openWizard() and wizardSubmit() functions for the
//! multi-step creation modal, plus a keydown handler that prevents
//! space bar from submitting forms outside input fields.
//!
//! Usage:
//!   let js = wizard_script();  // include in <script> block

/// Return the wizard JS functions (already double-braced for format!)
pub fn wizard_script() -> &'static str {
    r#"  function fieldInput(f) {
    const n = f.name.toLowerCase();
    const t = f.type.toLowerCase();
    // Dropdown for known enum-like fields
    if (n === 'power_type' || n === 'power type') {
      return '<select name="' + f.name + '" class="w-full bg-surface-0 border border-surface-4 rounded px-3 py-2 text-sm text-gray-100 focus:border-brand focus:outline-none"><option value="AC">AC</option><option value="DC">DC</option></select>';
    }
    if (n === 'chemistry') {
      return '<select name="' + f.name + '" class="w-full bg-surface-0 border border-surface-4 rounded px-3 py-2 text-sm text-gray-100 focus:border-brand focus:outline-none"><option value="LiFePO4">LiFePO4</option><option value="AGM">AGM</option><option value="flooded lead-acid">Flooded Lead-Acid</option></select>';
    }
    if (n === 'controller_type' || n === 'controller type') {
      return '<select name="' + f.name + '" class="w-full bg-surface-0 border border-surface-4 rounded px-3 py-2 text-sm text-gray-100 focus:border-brand focus:outline-none"><option value="MPPT">MPPT</option><option value="PWM">PWM</option></select>';
    }
    if (n === 'phase') {
      return '<select name="' + f.name + '" class="w-full bg-surface-0 border border-surface-4 rounded px-3 py-2 text-sm text-gray-100 focus:border-brand focus:outline-none"><option value="single">Single</option><option value="split">Split Phase</option></select>';
    }
    if (n === 'type' && f.name === 'type') {
      return '<select name="' + f.name + '" class="w-full bg-surface-0 border border-surface-4 rounded px-3 py-2 text-sm text-gray-100 focus:border-brand focus:outline-none"><option value="breaker">Breaker</option><option value="ANL fuse">ANL Fuse</option><option value="blade fuse">Blade Fuse</option></select>';
    }
    // Number input for numeric types
    const inputType = (t === 'float' || t === 'integer' || t === 'int') ? 'number' : 'text';
    const step = t === 'float' ? ' step="any"' : '';
    const ph = t === 'float' ? '0.0' : t === 'integer' ? '0' : '';
    return '<input name="' + f.name + '" type="' + inputType + '"' + step + ' placeholder="' + (ph || humanize(f.name)) + '" class="w-full bg-surface-0 border border-surface-4 rounded px-3 py-2 text-sm text-gray-100 focus:border-brand focus:outline-none">';
  }
  function openWizard(domain, cmd, fields) {
    const modal = document.createElement('div');
    modal.className = 'fixed inset-0 bg-black/60 flex items-center justify-center z-50';
    modal.onclick = function(e) { if (e.target === modal) modal.remove(); };
    // Use grid: 2 columns for 4+ fields, 1 for fewer
    const cols = fields.length >= 4 ? 'grid-cols-2' : 'grid-cols-1';
    let fieldHtml = '<div class="grid ' + cols + ' gap-3">';
    fields.forEach(f => {
      fieldHtml += '<div><label class="block text-xs text-gray-400 mb-1">' +
        humanize(f.name) + '</label>' + fieldInput(f) + '</div>';
    });
    fieldHtml += '</div>';
    modal.innerHTML = '<div class="bg-surface-2 rounded-xl p-6 max-w-lg w-full mx-4 border border-surface-3 shadow-2xl">' +
      '<h2 class="text-xl font-bold text-brand mb-4">' + humanize(cmd) + '</h2>' +
      '<form onsubmit="return wizardSubmit(this, \'' + domain + '\', \'' + cmd + '\')">' +
      fieldHtml +
      '<div class="flex gap-3 mt-4">' +
      '<button type="submit" class="px-6 py-2 bg-brand text-surface-0 font-medium rounded-lg hover:bg-brand-dim transition">' + humanize(cmd) + '</button>' +
      '<button type="button" onclick="this.closest(\'div.fixed\').remove()" class="px-4 py-2 bg-surface-3 text-gray-300 rounded-lg hover:bg-surface-4 transition">Cancel</button>' +
      '</div>' +
      '<div class="wizard-result mt-3"></div>' +
      '</form></div>';
    document.body.appendChild(modal);
    modal.querySelector('input,select')?.focus();
  }
  function wizardSubmit(form, domain, cmd) {
    const data = {};
    new FormData(form).forEach((v, k) => { if(v) data[k] = v; });
    fetch('/domains/' + domain + '/dispatch', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({command: cmd, attrs: data})
    }).then(r => r.json()).then(r => {
      const el = form.querySelector('.wizard-result');
      if (r.ok) {
        // Top-level success badge.
        var html = '<div class="p-3 rounded bg-emerald-900/40 text-emerald-300 text-sm">\u2714 ' + humanize(r.event) + ' \u2014 ' + humanize(r.aggregate_type) + ' #' + r.aggregate_id + '</div>';
        // Cascade trail \u2014 every downstream event emitted during
        // this dispatch (i545). Each becomes a chip showing the
        // event name + aggregate. First entry usually duplicates
        // the top-level event ; skip it when ids match.
        if (Array.isArray(r.cascade) && r.cascade.length > 0) {
          var chips = r.cascade
            .filter(function(ev) { return !(ev.aggregate_id === r.aggregate_id && ev.name === r.event); })
            .map(function(ev) {
              return '<span class="inline-block px-2 py-1 mr-1 mt-2 rounded text-xs bg-brand/10 text-brand border border-brand/30">' +
                '\u21aa ' + humanize(ev.name || '') +
                (ev.aggregate_type ? ' \u00b7 ' + humanize(ev.aggregate_type) : '') +
                (ev.aggregate_id ? ' #' + ev.aggregate_id : '') +
                '</span>';
            }).join('');
          if (chips) {
            html += '<div class="mt-2 text-xs text-gray-400">cascade :</div><div>' + chips + '</div>';
            // Log each cascade event to the event stream too.
            r.cascade.forEach(function(ev) {
              if (ev.aggregate_id === r.aggregate_id && ev.name === r.event) return;
              addEvent(ev.name, cmd, ev.aggregate_type, ev.aggregate_id, true);
            });
          }
        }
        el.innerHTML = html;
        addEvent(r.event, cmd, r.aggregate_type, r.aggregate_id, true);
        form.querySelectorAll('input').forEach(function(i) { i.value = ''; });
        // Auto-dismiss only when there's no cascade to read.
        if (!Array.isArray(r.cascade) || r.cascade.length <= 1) {
          setTimeout(function() { form.closest('div.fixed')?.remove(); }, 1500);
        }
      } else {
        // Humanized error (i540). Worker now returns either a string
        // OR an object { message, suggestion, field }.
        var err = r.error;
        var msg, suggestion, field;
        if (err && typeof err === 'object') {
          msg = err.message || JSON.stringify(err);
          suggestion = err.suggestion;
          field = err.field;
        } else {
          msg = String(err || 'dispatch failed');
        }
        var body = '<div class="p-3 rounded bg-red-900/40 text-red-300 text-sm">\u2718 ' + msg;
        if (suggestion) body += '<div class="text-xs text-red-200 mt-1">' + suggestion + '</div>';
        body += '</div>';
        el.innerHTML = body;
        if (field) {
          var input = form.querySelector('[name="' + field + '"]');
          if (input) {
            input.classList.add('ring-2', 'ring-red-400');
            input.focus();
          }
        }
        addEvent(msg, cmd, '', '', false);
      }
    });
    return false;
  }
  document.addEventListener('keydown', function(e) {
    if (e.key === ' ' && e.target.tagName !== 'INPUT' && e.target.tagName !== 'TEXTAREA') {
      e.preventDefault();
    }
  });"#
}
