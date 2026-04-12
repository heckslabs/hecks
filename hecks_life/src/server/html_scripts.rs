//! Core JS functions — command dispatch, event stream, table interactions
//!
//! Provides submitCmd, humanize, addEvent, and UI helper functions
//! used across the app shell. Double-braced for Rust format! strings.
//!
//! Usage:
//!   let js = core_script();  // include in <script> block

/// Return core JS functions (already double-braced for format!)
pub fn core_script() -> &'static str {
    r#"  function submitCmd(form, cmd) {{
    const data = {{}};
    new FormData(form).forEach((v, k) => {{ if(v) data[k] = v; }});
    fetch(form.action, {{
      method: 'POST',
      headers: {{'Content-Type': 'application/json'}},
      body: JSON.stringify({{command: cmd, attrs: data}})
    }}).then(r => r.json()).then(r => {{
      const el = form.querySelector('.cmd-result');
      el.classList.remove('hidden', 'bg-emerald-900/40', 'text-emerald-300', 'bg-red-900/40', 'text-red-300');
      if (r.ok) {{
        el.textContent = '\u2714 Done — ' + (r.event || 'success');
        el.classList.add('bg-emerald-900/40', 'text-emerald-300');
        form.querySelectorAll('input').forEach(i => i.value = '');
        addEvent(r.event, cmd, r.aggregate_type, r.aggregate_id, true);
      }} else {{
        el.textContent = '\u2718 Error: ' + r.error;
        el.classList.add('bg-red-900/40', 'text-red-300');
        addEvent(r.error, cmd, '', '', false);
      }}
    }});
    return false;
  }}
  function humanize(s) {{ return s.replace(/([a-z])([A-Z])/g, '$1 $2').replace(/_/g, ' '); }}
  function addEvent(event, cmd, aggType, aggId, ok) {{
    const stream = document.getElementById('event-stream');
    if (!stream) return;
    const hint = stream.querySelector('p.italic');
    if (hint) hint.remove();
    const time = new Date().toLocaleTimeString();
    const color = ok ? 'border-emerald-600/40' : 'border-red-600/40';
    const icon = ok ? '\u26A1' : '\u274C';
    const card = document.createElement('div');
    card.className = 'p-3 rounded-lg bg-surface-2 border ' + color + ' cursor-pointer hover:bg-surface-3 transition text-xs animate-pulse';
    card.innerHTML = '<div class="flex items-center justify-between mb-1"><span class="font-bold text-brand">' + icon + ' ' + humanize(event||cmd) + '</span><span class="text-gray-600">' + time + '</span></div>' +
      (aggType ? '<p class="text-gray-400">' + humanize(aggType) + (aggId ? ' #' + aggId : '') + '</p>' : '') +
      '<p class="text-gray-500 mt-1">' + humanize(cmd) + '</p>';
    card.onclick = function() {{
      card.classList.toggle('ring-1');
      card.classList.toggle('ring-brand/50');
    }};
    stream.insertBefore(card, stream.firstChild);
    setTimeout(() => card.classList.remove('animate-pulse'), 1000);
  }}
  function toggleCmd(btn) {{
    const form = btn.nextElementSibling;
    if (form) form.classList.toggle('hidden');
  }}
  function filterByStatus(el, status) {{
    const table = (el.closest('[data-domain-aggregate]') || el.parentElement.parentElement).querySelector('table') || document.querySelector('table');
    if (!table) return;
    const rows = table.querySelectorAll('tbody tr'), isActive = el.classList.contains('ring-2');
    el.parentElement.querySelectorAll('span').forEach(s => s.classList.remove('ring-2', 'ring-white'));
    if (isActive) {{ rows.forEach(r => r.style.display = ''); return; }}
    el.classList.add('ring-2', 'ring-white');
    rows.forEach(r => {{ r.style.display = r.textContent.toLowerCase().includes(status.toLowerCase()) ? '' : 'none'; }});
  }}
  function showDetail(row) {{
    const cells = row.querySelectorAll('td');
    const headers = row.closest('table').querySelectorAll('th');
    let fields = '';
    headers.forEach((h, i) => {{
      if (cells[i]) {{
        const label = h.textContent;
        const value = cells[i].textContent;
        fields += '<div><label class="block text-xs text-gray-400 mb-1">' + label + '</label><input value="' + value + '" class="w-full bg-surface-0 border border-surface-4 rounded px-3 py-1.5 text-sm text-gray-100"></div>';
      }}
    }});
    const modal = document.createElement('div');
    modal.className = 'fixed inset-0 bg-black/60 flex items-center justify-center z-50';
    modal.onclick = function(e) {{ if (e.target === modal) modal.remove(); }};
    modal.innerHTML = '<div class="bg-surface-2 rounded-xl p-6 max-w-lg w-full mx-4 border border-surface-3"><h3 class="text-lg font-bold text-brand mb-4">Record Detail</h3><div class="grid grid-cols-2 gap-3">' + fields + '</div><div class="mt-4 flex gap-3"><button onclick="this.closest(\'div.fixed\').remove()" class="px-4 py-1.5 bg-surface-3 rounded text-sm text-brand border border-surface-4">Close</button></div></div>';
    document.body.appendChild(modal);
  }}
  function showTab(tab) {{
    ['records','build'].forEach(t => {{
      document.getElementById('panel-'+t).classList.toggle('hidden', tab !== t);
      const btn = document.getElementById('tab-'+t);
      btn.classList.toggle('text-brand', tab === t);
      btn.classList.toggle('border-brand', tab === t);
      btn.classList.toggle('text-gray-400', tab !== t);
      btn.classList.toggle('border-transparent', tab !== t);
    }});
  }}
  function searchTable(input) {{
    const table = input.closest('div').parentElement.querySelector('table');
    if (!table) return;
    const query = input.value.toLowerCase();
    table.querySelectorAll('tbody tr').forEach(row => {{
      row.style.display = row.textContent.toLowerCase().includes(query) ? '' : 'none';
    }});
  }}
  function sortTable(th) {{
    const table = th.closest('table');
    const idx = Array.from(th.parentElement.children).indexOf(th);
    const rows = Array.from(table.querySelectorAll('tbody tr'));
    const asc = th.dataset.sort !== 'asc';
    rows.sort((a, b) => {{
      const va = a.children[idx]?.textContent || '';
      const vb = b.children[idx]?.textContent || '';
      return asc ? va.localeCompare(vb) : vb.localeCompare(va);
    }});
    th.dataset.sort = asc ? 'asc' : 'desc';
    const tbody = table.querySelector('tbody');
    rows.forEach(r => tbody.appendChild(r));
    th.parentElement.querySelectorAll('th').forEach(t => t.textContent = t.textContent.replace(/ ▲| ▼/g, ''));
    th.textContent += asc ? ' ▲' : ' ▼';
  }}"#
}
