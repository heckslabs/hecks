//! Rendering for `storehouse persistence-map` — a fixed-width human table and
//! a `--json` form for tooling. Split from `mod.rs` to keep each file under the
//! 200-LoC limit. Pure formatting : no IO beyond building the returned String
//! (the table path reads `info_dir` only to print it as a header line).

use super::Row;

/// Group rows by their `source` label and count them — the at-a-glance summary
/// (declared :heki / declared :memory / unwired → default / …), sorted by label.
fn counts_by_source(rows: &[Row]) -> Vec<(String, usize)> {
    let mut map: std::collections::BTreeMap<String, usize> = std::collections::BTreeMap::new();
    for r in rows {
        *map.entry(r.source.clone()).or_insert(0) += 1;
    }
    map.into_iter().collect()
}

/// Fixed-width human table : summary, the per-aggregate rows, then the orphan
/// section (live stores no aggregate claims — the G3 universe).
pub fn render_table(rows: &[Row], orphans: &[String], info_dir: &str) -> String {
    let mut s = String::new();
    s.push_str(&format!("persistence-map — {} aggregates\n", rows.len()));
    s.push_str(&format!("info_dir: {info_dir}\n\n"));

    s.push_str("summary by source:\n");
    for (src, n) in counts_by_source(rows) {
        s.push_str(&format!("  {n:>4}  {src}\n"));
    }
    let live = rows.iter().filter(|r| r.live_store).count();
    s.push_str(&format!("  {live:>4}  (of which have a live store)\n\n"));

    let w = rows.iter().map(|r| r.fqn.len()).max().unwrap_or(3).max(3);
    s.push_str(&format!("{:<w$}  {:<20}  live\n", "FQN", "SOURCE", w = w));
    s.push_str(&format!("{}\n", "-".repeat(w + 28)));
    for r in rows {
        s.push_str(&format!(
            "{:<w$}  {:<20}  {}\n",
            r.fqn,
            r.source,
            if r.live_store { "●" } else { "" },
            w = w,
        ));
    }

    // i728 G3 — account for every orphan (non-aggregate writer) against the
    // boundary lists (classify.rs). `unknown` is the genuinely-UNACCOUNTED set ;
    // the comb is complete only when it reaches zero. PM-instance stores are
    // their own category (process-manager engine state, not aggregates).
    let mut by_cat: std::collections::BTreeMap<&str, Vec<&String>> = std::collections::BTreeMap::new();
    for o in orphans {
        let cat = if o.starts_with("process_managers/") {
            "pm-instance"
        } else {
            crate::run_boot::classify::classify_name(o)
        };
        by_cat.entry(cat).or_default().push(o);
    }
    let unknown = by_cat.get("unknown").map(|v| v.len()).unwrap_or(0);
    s.push_str(&format!(
        "\norphan stores ({} — live under information/, no aggregate ; {} genuinely UNACCOUNTED):\n",
        orphans.len(),
        unknown
    ));
    if orphans.is_empty() {
        s.push_str("  (none)\n");
    } else {
        for (cat, items) in &by_cat {
            s.push_str(&format!("  [{}] ({}):\n", cat, items.len()));
            for o in items {
                s.push_str(&format!("    {o}\n"));
            }
        }
    }
    s.push_str(
        "\nnote: :memory is INERT until apply_memory_persistence lands (Phase B step 0) —\n\
         every unwired AND every declared-:memory aggregate resolves to heki TODAY.\n",
    );
    s
}

/// JSON form for tooling : `{ aggregates: [{fqn, declared, source, live_store}], orphans: [..] }`.
/// Hand-rolled (no serde dep in this crate's CLI path) ; values are simple
/// strings/bools so escaping is limited to the quote/backslash pair.
pub fn render_json(rows: &[Row], orphans: &[String]) -> String {
    let mut s = String::from("{\"aggregates\":[");
    for (i, r) in rows.iter().enumerate() {
        if i > 0 {
            s.push(',');
        }
        let declared = match &r.declared {
            Some(d) => format!("\"{}\"", esc(d)),
            None => "null".to_string(),
        };
        s.push_str(&format!(
            "{{\"fqn\":\"{}\",\"declared\":{},\"source\":\"{}\",\"live_store\":{}}}",
            esc(&r.fqn),
            declared,
            esc(&r.source),
            r.live_store,
        ));
    }
    s.push_str("],\"orphans\":[");
    for (i, o) in orphans.iter().enumerate() {
        if i > 0 {
            s.push(',');
        }
        s.push_str(&format!("\"{}\"", esc(o)));
    }
    s.push_str("]}");
    s
}

fn esc(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}
