// [antibody-exempt: rust/src/server/html_query.rs — storehouse engine served-UI
//  rendering. Kernel Rust transport that PROJECTS a bluebook's declared queries
//  into runnable cards ; the queries themselves are bluebook vocabulary, this is
//  only the surface that runs them. Same engine-surface class as routes.rs,
//  whose /query door it posts to.]
//! Query rendering — run an aggregate's queries from the served page
//!
//! The walking skeleton has always LISTED an aggregate's queries in the
//! sidebar without offering any way to RUN one : commands were runnable,
//! reads were not. This module closes that half, mirroring the command
//! surface exactly — one collapsible `<details>` card per query, typed
//! inputs delegated to `html_form::field_input` (the same renderer the
//! command forms use), and a submit button that POSTs to the domain's
//! `/query` door.
//!
//! The wire verb is the query's FQN — `<Context>::<Aggregate>.<snake_verb>`,
//! context falling back to the domain name — which is the address the
//! `embed::gated_query` FQN arm resolves. Queries with no declared
//! attributes render as a bare button : one click, no inputs.
//!
//! A result is ALWAYS `{aggregate, query, state:[...]}` with `state` a
//! LIST — one row, many rows, or none. `queryRowsHtml` renders the list,
//! never a bare object, so a second row can never break the table.
//!
//! Usage:
//!   let html = render_agg_queries(domain, agg, rt);
//!   let js   = query_script();  // include in the <script> block

use crate::ir::Aggregate;
use crate::runtime::Runtime;
use super::html_shared::{display_name, esc};
use super::html_form::field_input;

/// Stable DOM id for one query's card — the sidebar's query links jump
/// here, so a listed query is now one click from being run.
pub fn query_anchor(agg: &str, query: &str) -> String {
    format!("qry-{}-{}", agg, query)
}

/// Render every query on an aggregate as a stacked `<details>` panel,
/// styled identically to the command panels above it. Collapsed by
/// default — commands are the page's primary verb ; reads are the
/// second look.
pub fn render_agg_queries(domain: &str, agg: &Aggregate, rt: &Runtime) -> String {
    if agg.queries.is_empty() {
        return String::new();
    }
    let context = agg.context.clone().unwrap_or_else(|| rt.domain.name.clone());
    let mut s = String::new();
    s.push_str(
        r#"<div class="mt-3 mb-1 text-[0.6rem] font-bold uppercase tracking-widest text-gray-600">Queries</div><div class="space-y-2">"#,
    );

    for q in &agg.queries {
        let verb = format!(
            "{}::{}.{}",
            context,
            agg.name,
            crate::util::snake_case(&q.name),
        );
        let goal_html = match q.description.as_deref().unwrap_or("") {
            "" => String::new(),
            g => format!(r#"<p class="text-xs text-gray-500 mb-2">{}</p>"#, esc(g)),
        };
        s.push_str(&format!(
            r#"<details id="{anchor}" data-domain-query="{qname}" class="bg-surface-1 rounded-lg border border-surface-3 scroll-mt-24">
  <summary class="cursor-pointer px-3 py-2 text-sm font-medium text-white hover:bg-surface-3 rounded-t-lg flex items-center justify-between">
    <span><span class="text-teal-400">◎</span> {label}</span>
    <span class="text-xs text-gray-500">{shape}</span>
  </summary>
  <div class="px-3 pb-3 pt-1">
    {goal_html}
    {form}
  </div>
</details>"#,
            anchor = esc(&query_anchor(&agg.name, &q.name)),
            qname = esc(&q.name),
            label = esc(&display_name(&q.name)),
            shape = esc(&shape_hint(q)),
            goal_html = goal_html,
            form = render_query_form(domain, &verb, agg, q, rt),
        ));
    }

    s.push_str("</div>");
    s
}

/// A one-glance summary of what the query DOES to the record set —
/// filters, ordering, cap, reduction. Purely a hint ; the runtime is
/// still the authority on the answer.
fn shape_hint(q: &crate::ir::Query) -> String {
    let mut parts: Vec<String> = Vec::new();
    if !q.wheres.is_empty() {
        parts.push(format!("{} filter{}", q.wheres.len(), if q.wheres.len() == 1 { "" } else { "s" }));
    }
    if q.order_by.is_some() {
        parts.push("ordered".to_string());
    }
    if q.limit.is_some() {
        parts.push("limited".to_string());
    }
    parts.join(" · ")
}

/// The `<form>` for one query : a typed input per declared attribute
/// (the kwargs the where-clauses reference), then a Run button. No
/// attributes means no inputs — the button alone.
fn render_query_form(
    domain: &str, verb: &str, agg: &Aggregate, q: &crate::ir::Query, rt: &Runtime,
) -> String {
    let mut s = String::new();
    s.push_str(&format!(
        r#"<form onsubmit="return querySubmit(this, '{domain}', '{verb}')" class="space-y-2">"#,
        domain = esc(domain),
        verb = esc(verb),
    ));

    if !q.attributes.is_empty() {
        let cols = if q.attributes.len() <= 3 { "grid-cols-1" } else { "grid-cols-2" };
        s.push_str(&format!(r#"<div class="grid {} gap-2">"#, cols));
        for attr in &q.attributes {
            s.push_str(&field_input(agg, attr, rt));
        }
        s.push_str("</div>");
    }

    s.push_str(
        r#"<button type="submit" class="w-full px-4 py-2 bg-teal-500/10 border border-teal-400/30 rounded-lg text-teal-300 text-sm font-medium hover:bg-teal-500/20 transition mt-2">Run</button>
      <div class="query-result"></div>
    </form>"#,
    );
    s
}

/// `querySubmit` + `queryRowsHtml` — the read half of the served UI's
/// JS. Deliberately shaped like `wizardSubmit` : same FormData harvest,
/// same `authHeaders` bearer attach, same `showDenial` governance
/// banner, so a denied READ looks exactly like a denied WRITE.
pub fn query_script() -> &'static str {
    r#"  function querySubmit(form, domain, verb) {
    var data = {};
    new FormData(form).forEach(function (v, k) { if (v) data[k] = v; });
    var el = form.querySelector('.query-result');
    el.innerHTML = '<div class="mt-2 text-xs text-gray-500">running…</div>';
    fetch('/domains/' + encodeURIComponent(domain) + '/query', {
      method: 'POST',
      headers: authHeaders({'Content-Type': 'application/json'}),
      body: JSON.stringify({command: verb, attrs: data})
    }).then(function (resp) {
      return resp.json().then(function (r) {
        if (r && r.ok === false) {
          el.innerHTML = '<div class="mt-2 p-3 rounded bg-red-900/40 text-red-300 text-sm">✘ ' +
            escapeHtml(denialText(r.error)) + '</div>';
          if (isGovernanceDenial(resp.status, r)) showDenial(denialText(r.error), verb);
          return;
        }
        el.innerHTML = queryRowsHtml(r);
      });
    }).catch(function (e) {
      el.innerHTML = '<div class="mt-2 p-3 rounded bg-red-900/40 text-red-300 text-sm">✘ ' +
        escapeHtml(String(e)) + '</div>';
    });
    return false;
  }
  function escapeHtml(s) {
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;')
      .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }
  function queryCell(v) {
    if (v === null || v === undefined) return '';
    if (typeof v === 'object') return JSON.stringify(v);
    return String(v);
  }
  function queryRowsHtml(r) {
    // `state` is ALWAYS a list — one row, many, or none. Anything else is
    // a scalar reduction, wrapped so the same table renders it.
    var rows = (r && r.state !== undefined) ? r.state : [];
    if (!Array.isArray(rows)) rows = [rows];
    if (!rows.length) {
      return '<div class="mt-2 p-3 rounded bg-surface-0 border border-surface-3 text-xs text-gray-500">no rows</div>';
    }
    var cols = [];
    rows.forEach(function (row) {
      if (row && typeof row === 'object' && !Array.isArray(row)) {
        Object.keys(row).forEach(function (k) { if (cols.indexOf(k) === -1) cols.push(k); });
      }
    });
    var head = '', body = '';
    if (cols.length) {
      head = cols.map(function (c) {
        return '<th class="text-left font-medium py-1 pr-3 whitespace-nowrap">' +
          escapeHtml(humanize(c)) + '</th>';
      }).join('');
      body = rows.map(function (row) {
        return '<tr class="border-t border-surface-3/60">' + cols.map(function (c) {
          return '<td class="py-1 pr-3 text-gray-300 align-top">' +
            escapeHtml(queryCell(row ? row[c] : '')) + '</td>';
        }).join('') + '</tr>';
      }).join('');
    } else {
      head = '<th class="text-left font-medium py-1 pr-3">value</th>';
      body = rows.map(function (row) {
        return '<tr class="border-t border-surface-3/60"><td class="py-1 pr-3 text-gray-300">' +
          escapeHtml(queryCell(row)) + '</td></tr>';
      }).join('');
    }
    return '<div class="mt-2 rounded-lg border border-surface-3 bg-surface-0 p-3">' +
      '<div class="text-[0.6rem] uppercase tracking-widest text-gray-600 mb-1">' +
      rows.length + ' row' + (rows.length === 1 ? '' : 's') + '</div>' +
      '<div class="overflow-x-auto"><table class="w-full text-xs"><thead class="text-gray-500"><tr>' +
      head + '</tr></thead><tbody>' + body + '</tbody></table></div></div>';
  }"#
}
