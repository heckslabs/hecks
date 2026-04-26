//! Phase 8 — SurfaceWakeReport
//!
//! If `<info>/wake_report.heki` exists with `phase=filed`, print the
//! report inline before the runner returns control. Mirrors
//! boot_miette.sh lines 339-350.
//!
//! The boot.bluebook description mentions /tmp/wake_review_latest.md
//! as the surface ; that's the markdown render. The heki record is
//! the source of truth (it carries the `phase` lifecycle field that
//! gates the print).

use crate::heki;

pub fn surface(info_dir: &str) {
    let path = format!("{}/wake_report.heki", info_dir.trim_end_matches('/'));
    let store = match heki::read(&path) {
        Ok(s) if !s.is_empty() => s,
        _ => return,
    };
    let mut items: Vec<&heki::Record> = store.values().collect();
    items.sort_by(|a, b| ts(a).cmp(&ts(b)));
    let rec = match items.last() { Some(r) => *r, None => return };

    let phase = field(rec, "phase");
    if phase != "filed" { return; }

    println!();
    println!("── wake report (unconsumed) ──");
    println!("  woke at:         {}", field(rec, "woke_at"));
    println!("  dreams:          {}", field(rec, "dreams_count"));
    println!("  dominant tokens: {}", field(rec, "dominant_tokens"));
    println!("  recurring theme: {}", field(rec, "recurring_theme"));
    println!("  witness firings: {}", field(rec, "witness_firings"));
    println!("  invariant held:  {}", field(rec, "invariant_held"));
    let body = field(rec, "body_reflection");
    if !body.is_empty() && body != "—" {
        println!();
        println!("  body reflection:");
        println!("    {}", body);
    }
    println!();
    println!(
        "  (mark consumed with: hecks-life heki upsert {} id=latest phase=consumed)",
        path,
    );
}

fn field(rec: &heki::Record, key: &str) -> String {
    match rec.get(key) {
        Some(serde_json::Value::String(s)) => s.clone(),
        Some(serde_json::Value::Number(n)) => n.to_string(),
        Some(serde_json::Value::Bool(b)) => b.to_string(),
        _ => "—".into(),
    }
}

fn ts(r: &heki::Record) -> String {
    r.get("updated_at").or_else(|| r.get("created_at"))
        .and_then(|v| v.as_str()).unwrap_or("").to_string()
}
