//! Sidebar navigation — grouped domain links and utility helpers
//!
//! Generates the sidebar HTML with domains grouped under category
//! headers (Operations, Products, Sales, Compliance).
//!
//! Usage:
//!   let links = sidebar_links(&domains, Some("manufacturing"));

/// Generate sidebar nav links from domain names, highlighting active
pub fn sidebar_links(domains: &[(String, usize)], active: Option<&str>) -> String {
    let groups: &[(&str, &[&str])] = &[
        ("Operations", &["manufacturing", "inventory", "supply_chain", "distribution", "quality"]),
        ("Products", &["catalog", "formulation", "formulation_lab", "pricing"]),
        ("Sales", &["brand_strategy", "customer_personas", "storefront"]),
        ("Compliance", &["compliance", "regulatory_compliance", "claims", "demand"]),
    ];
    let mut out = String::new();
    let mut placed = std::collections::HashSet::new();
    for (header, members) in groups {
        let group_domains: Vec<_> = members.iter()
            .filter_map(|m| domains.iter().find(|(n, _)| n == m))
            .collect();
        if group_domains.is_empty() { continue; }
        out.push_str(&format!(
            r#"<div class="mt-4 mb-1 px-3 text-xs font-bold uppercase tracking-wider text-gray-600">{}</div>"#,
            header
        ));
        for (name, _count) in &group_domains {
            placed.insert(name.clone());
            out.push_str(&sidebar_link(name, active));
        }
    }
    // Ungrouped domains
    let ungrouped: Vec<_> = domains.iter().filter(|(n, _)| !placed.contains(n)).collect();
    if !ungrouped.is_empty() && !placed.is_empty() {
        out.push_str(r#"<div class="mt-4 mb-1 px-3 text-xs font-bold uppercase tracking-wider text-gray-600">Other</div>"#);
    }
    for (name, _) in ungrouped {
        out.push_str(&sidebar_link(name, active));
    }
    out
}

fn sidebar_link(name: &str, active: Option<&str>) -> String {
    let active_class = if active == Some(name) {
        "bg-brand/15 text-brand border-l-2 border-brand font-semibold"
    } else {
        "text-gray-400 hover:bg-surface-2 hover:text-white"
    };
    let icon = super::html_shared::domain_icon(name);
    let label = super::html_shared::display_name(name);
    format!(
        r#"<a href="/domains/{name}" data-domain-aggregate="{name}" title="Open {label}" class="block px-3 py-1.5 rounded-lg text-sm {active_class} transition cursor-pointer">
  {icon} {label}
</a>"#,
    )
}

/// Hierarchical sidebar — used on a domain page so the operator can
/// navigate inside the active domain (Aggregate ▸ Commands ▸ Queries
/// ▸ References) without leaving the page. Click any leaf scrolls to
/// the matching anchor on the page ; cross-domain references navigate
/// to the sibling domain.
pub fn sidebar_tree(
    domains: &[(String, usize)],
    active: &str,
    active_domain: &crate::ir::Domain,
) -> String {
    use super::html_shared::{display_name, esc};
    let mut out = String::new();

    // Universe link — top of the rail.
    out.push_str(
        r#"<a href="/diagram" class="block px-3 py-1.5 rounded-lg text-sm text-gray-400 hover:bg-surface-2 hover:text-white transition cursor-pointer mb-2 border border-surface-3">
  🌌 Universe Diagram
</a>"#,
    );

    // Active domain header + tree. The domain-level <details> stays
    // open by default ; per-aggregate <details> default to closed and
    // a tiny client-side script (i111) opens the URL-hash target and
    // any aggregates the operator previously expanded, keyed by
    // `localStorage['bin-buddy.sidebar.<aggregate>']`.
    out.push_str(&format!(
        r#"<div class="mt-2 mb-1 px-3 text-xs font-bold uppercase tracking-wider text-brand/80">Active Domain</div>
<details open class="mb-1">
  <summary class="block px-3 py-1.5 rounded-lg text-sm bg-brand/15 text-brand border-l-2 border-brand font-semibold cursor-pointer">
    {icon} {label}
  </summary>
  <div class="ml-2 mt-1 space-y-2 border-l border-surface-3 pl-2">
"#,
        icon = super::html_shared::domain_icon(active),
        label = esc(&display_name(active)),
    ));

    for agg in &active_domain.aggregates {
        let agg_anchor = format!("agg-{}", agg.name);
        let cmd_count = agg.commands.len();
        let qry_count = agg.queries.len();
        let vo_count  = agg.value_objects.len();
        let vo_suffix = if vo_count > 0 { format!(" · {vo_count}vo") } else { String::new() };
        out.push_str(&format!(
            r##"<details data-sidebar-agg="{name}" class="bg-surface-2 rounded-lg border border-surface-3">
  <summary class="px-3 py-2 cursor-pointer flex items-center justify-between text-sm font-semibold text-white hover:bg-surface-3 rounded-t-lg">
    <a href="#{anchor}" class="hover:text-brand transition" onclick="event.stopPropagation()">{icon} {label}</a>
    <span class="text-xs text-gray-500">{cn}c · {qn}q{vn}</span>
  </summary>
  <div class="px-2 pb-2 pt-1 space-y-0.5">
"##,
            name = esc(&agg.name),
            anchor = agg_anchor,
            icon = super::html_shared::module_icon(&agg.name),
            label = esc(&display_name(&agg.name)),
            cn = cmd_count,
            qn = qry_count,
            vn = vo_suffix,
        ));

        // Commands — link to the parent aggregate anchor (the form
        // rendered by creation_cards covers every command on that
        // aggregate as one unified surface, so all cmd links land
        // there). Future : per-command anchors when the page splits
        // forms by command.
        let agg_jump = format!("agg-{}", agg.name);
        if !agg.commands.is_empty() {
            out.push_str(r#"<div class="px-2 pt-1 text-[0.6rem] font-bold uppercase tracking-widest text-gray-600">Commands</div>"#);
            for cmd in &agg.commands {
                out.push_str(&format!(
                    r##"<a href="#{anchor}" class="flex items-center gap-1.5 px-2 py-1 rounded text-xs text-gray-300 hover:bg-brand/10 hover:text-brand transition truncate">
  <span class="text-blue-400 text-[0.5rem]">◉</span> {label}
</a>"##,
                    anchor = agg_jump,
                    label = esc(&display_name(&cmd.name)),
                ));
            }
        }

        // Queries — same jump-to-parent shortcut.
        if !agg.queries.is_empty() {
            out.push_str(r#"<div class="px-2 pt-1 text-[0.6rem] font-bold uppercase tracking-widest text-gray-600">Queries</div>"#);
            for q in &agg.queries {
                out.push_str(&format!(
                    r##"<a href="#{anchor}" class="flex items-center gap-1.5 px-2 py-1 rounded text-xs text-gray-300 hover:bg-brand/10 hover:text-brand transition truncate">
  <span class="text-teal-400 text-[0.5rem]">◎</span> {label}
</a>"##,
                    anchor = agg_jump,
                    label = esc(&display_name(&q.name)),
                ));
            }
        }

        // References — local jumps to other aggregates on this page,
        // cross-domain references to an aggregate in a sibling domain.
        // i548-follow-up : the framework runtime here only sees domain
        // names, not the aggregate inventory of each one ; cross-domain
        // aggregates (e.g. AuthIdentity from the framework's auth
        // adapter) get rendered as TEXT, not a dead link to
        // `/domains/<target>` that would 404. When the runtime gains a
        // cross-domain aggregate index, this can be re-elevated to a
        // navigable jump.
        if !agg.references.is_empty() {
            out.push_str(r#"<div class="px-2 pt-1 text-[0.6rem] font-bold uppercase tracking-widest text-gray-600">References</div>"#);
            for r in &agg.references {
                let local = active_domain.aggregates.iter().any(|a| a.name == r.target);
                if local {
                    let href = format!("#agg-{}", r.target);
                    out.push_str(&format!(
                        r#"<a href="{href}" class="flex items-center gap-1.5 px-2 py-1 rounded text-xs text-gray-300 hover:bg-brand/10 hover:text-brand transition truncate">
  <span class="text-[0.55rem]">→</span> {label}
</a>"#,
                        href = href,
                        label = esc(&display_name(&r.target)),
                    ));
                } else {
                    out.push_str(&format!(
                        r#"<div class="flex items-center gap-1.5 px-2 py-1 rounded text-xs text-cyan-400/60 cursor-default truncate" title="Cross-domain reference — not in any loaded domain">
  <span class="text-[0.55rem]">↗</span> {label} <span class="text-[0.55rem] text-gray-600 ml-auto">ext</span>
</div>"#,
                        label = esc(&display_name(&r.target)),
                    ));
                }
            }
        }

        out.push_str("</div></details>\n");
    }

    out.push_str("</div></details>\n");

    // Other domains — collapsed below the active one.
    out.push_str(r#"<div class="mt-4 mb-1 px-3 text-xs font-bold uppercase tracking-wider text-gray-600">Other Domains</div>"#);
    for (name, _count) in domains {
        if name == active { continue; }
        out.push_str(&sidebar_link(name, Some(active)));
    }

    // i111 — per-aggregate <details> default closed (server-rendered).
    // On DOMContentLoaded :
    //   * Open the aggregate matching `location.hash` (e.g. #agg-Customer
    //     → the Customer panel) ; this also handles the case where a
    //     user lands on a deep link from another page.
    //   * Restore any aggregate the operator previously expanded, keyed
    //     by `bin-buddy.sidebar.<AggregateName>` in localStorage. The
    //     namespace is `bin-buddy.sidebar` per i111 ; the walking
    //     skeleton's first user is bin-buddy so the namespace is fixed
    //     here ; renaming for other tenants is a future concern.
    // Listen for toggle events to persist subsequent open/close.
    out.push_str(r#"<script>
(function() {
  var KEY_PREFIX = 'bin-buddy.sidebar.';
  function init() {
    var hash = (location.hash || '').replace(/^#agg-/, '');
    document.querySelectorAll('details[data-sidebar-agg]').forEach(function(d) {
      var name = d.getAttribute('data-sidebar-agg');
      var stored = null;
      try { stored = localStorage.getItem(KEY_PREFIX + name); } catch (e) {}
      if (name === hash) {
        d.open = true;
      } else if (stored === 'open') {
        d.open = true;
      } else if (stored === 'closed') {
        d.open = false;
      }
      d.addEventListener('toggle', function() {
        try { localStorage.setItem(KEY_PREFIX + name, d.open ? 'open' : 'closed'); } catch (e) {}
      });
    });
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
</script>"#);

    out
}
