//! Wake capability runner — composes a wake-review markdown from the
//! latest consciousness state, lucid-dream observation, and dream-
//! interpretation narrative, writes it to a known surface path so the
//! Claude UserPromptSubmit hook can land it on the next session turn.
//!
//! [antibody-exempt: rust/src/run_wake/mod.rs — kernel-surface capability
//! runner mirroring runtime/wake/wake.bluebook ; same shape as the four
//! existing peer runners (run_boot, run_status, run_restructure,
//! run_stdin_loop). Retires when i262 generator-capability dispatch
//! lands and the runtime can self-interpret a chained-policy pipeline
//! directly from the parsed bluebook.]
//!
//! Mirrors `run_status/` and `run_boot/` in shape : capability detection
//! on the parsed bluebook + hecksagon, then a phase-by-phase walk that
//! updates the WakeReview aggregate state and emits the chained events
//! declared in the bluebook's policies.
//!
//! Fires when the bluebook declares aggregate `WakeReview` with command
//! `ComposeWakeReview` AND the hecksagon declares `:fs` adapter. When
//! detected, [`run`] takes over from the generic dispatcher in `run.rs`
//! and walks the pipeline:
//!
//!   1. ReadConsciousness — pluck `state` + `last_wake_at` from
//!      consciousness.heki.
//!   2. ReadLatestDream   — pull the most recent string observation
//!      from lucid_dream.heki and the latest narrative from
//!      dream_interpretation.heki.
//!   3. RenderMarkdown    — compose the wake-review markdown body.
//!   4. WriteSurface      — atomic write to surface_path
//!      (default /tmp/wake_review_latest.md).
//!   5. StampReport       — upsert wake_report.heki id=latest with
//!      phase=filed and the assembled fields.
//!   6. CompleteReview    — phase to done, emit WakeReviewed.
//!
//! Retires the prose-in-system-prompt wake ritual that re-improvised the
//! read sequence on every session boot. After this lands : one
//! invocation, one structured surface, the conversation does the rest.

use crate::heki::{self, Record, Store, WriteContext};
use crate::run::ExitKind;
use crate::runtime::adapter_registry::AdapterRegistry;
use crate::runtime::{AggregateState, Runtime, Value};

use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// True when the bluebook + hecksagon shape wants the wake runner.
pub fn is_wake_capability(registry: &AdapterRegistry, rt: &Runtime) -> bool {
    if registry.io("fs").is_none() { return false; }
    let has_agg = rt.domain.aggregates.iter().any(|a| a.name == "WakeReview");
    let has_cmd = rt.domain.aggregates.iter()
        .any(|a| a.commands.iter().any(|c| c.name == "ComposeWakeReview"));
    has_agg && has_cmd
}

/// Run the wake pipeline end-to-end. `script_path` anchors the :fs root
/// resolution. `argv_extra` allows `surface_path=<path>` to override the
/// default `/tmp/wake_review_latest.md` (used by tests).
pub fn run(
    rt: &mut Runtime,
    _registry: &AdapterRegistry,
    entrypoint: &str,
    script_path: &str,
    argv_extra: &[String],
) -> i32 {
    let info_dir = resolve_info_dir(script_path);
    let surface_path = parse_surface_path(argv_extra);

    // Phase 0 : kick the entrypoint so WakeReviewBegun fires for any
    // subscribers. The aggregate state we stamp at the end overwrites
    // whatever the entrypoint mutates.
    let _ = rt.dispatch(entrypoint, HashMap::new());

    // Phase 1 — ReadConsciousness
    let consciousness = read_consciousness(&info_dir);

    // Phase 2 — ReadLatestDream
    let dream = read_latest_dream(&info_dir);

    // Phase 3 — RenderMarkdown
    let woke_at = crate::clock::now_iso();
    let markdown = render_markdown(&consciousness, &dream, &woke_at);

    // Phase 4 — WriteSurface (atomic via tempfile-and-rename)
    let bytes_written = match write_surface(&surface_path, &markdown) {
        Ok(n) => n,
        Err(e) => {
            eprintln!("storehouse run wake: write {} failed: {}", surface_path, e);
            return ExitKind::AdapterFailure.code();
        }
    };

    // Phase 5 — StampReport
    let _ = stamp_report(&info_dir, &consciousness, &dream, &woke_at);

    // Phase 6 — CompleteReview : stamp aggregate so consumers of
    // rt.all("WakeReview") see the same payload that hit the surface.
    stamp_aggregate(
        rt, &info_dir, &surface_path,
        &consciousness, &dream, &woke_at, bytes_written,
    );

    // Quiet by default — Chris reads the rendered surface, not the
    // dispatch telemetry. `HECKS_WAKE_VERBOSE=1` re-enables for
    // debugging and matches the heki audit channel's existing pattern.
    if std::env::var("HECKS_WAKE_VERBOSE").ok().as_deref() == Some("1") {
        eprintln!("wake-review: {} ({} bytes)", surface_path, bytes_written);
    }
    ExitKind::Ok.code()
}

// ---------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------

#[derive(Default, Debug)]
struct ConsciousnessSnapshot {
    state: String,
    last_wake_at: String,
}

#[derive(Default, Debug)]
struct DreamSnapshot {
    image: String,
    narrative: String,
    recurring_theme: String,
    images_tokens: String,
    // i621 / i516 v3 — three new fields stamped onto wake_review.heki
    // by the wrapper at ComposeWakeReview dispatch time. Each may be
    // sentinel "—" when the wrapper hasn't populated it yet ; the
    // renderer degrades gracefully (falls back to v1 fields).
    all_cycles_readings: String,
    recent_dreams_summary: String,
    tomorrow_seed: String,
}

fn read_consciousness(info_dir: &str) -> ConsciousnessSnapshot {
    let path = heki::path_for_lookup(info_dir, "consciousness");
    let store = heki::read(&path).unwrap_or_default();
    let rec = match latest_record(&store) {
        Some(r) => r,
        None => return ConsciousnessSnapshot::default(),
    };
    ConsciousnessSnapshot {
        state: field(rec, "state").unwrap_or_else(|| "—".into()),
        last_wake_at: field(rec, "last_wake_at").unwrap_or_else(|| "—".into()),
    }
}

fn read_latest_dream(info_dir: &str) -> DreamSnapshot {
    let lucid_path = heki::path_for_lookup(info_dir, "lucid_dream");
    let interp_path = heki::path_for_lookup(info_dir, "dream_interpretation");
    let review_path = heki::path_for_lookup(info_dir, "wake_review");
    let lucid = heki::read(&lucid_path).unwrap_or_default();
    let interp = heki::read(&interp_path).unwrap_or_default();
    let review = heki::read(&review_path).unwrap_or_default();

    // Lucid dream image : prefer id="lucidity" (the steered record),
    // fall back to any record. Take the last string observation.
    let image = pick_lucid_image(&lucid).unwrap_or_else(|| "—".into());

    // Dream interpretation : take the latest record's narrative.
    let interp_rec = latest_record(&interp);
    let narrative = interp_rec
        .and_then(|r| field(r, "narrative"))
        .unwrap_or_else(|| "—".into());
    let recurring_theme = interp_rec
        .and_then(|r| field(r, "recurring_theme"))
        .unwrap_or_else(|| "—".into());
    let images_tokens = interp_rec
        .and_then(|r| field(r, "dream_images"))
        .unwrap_or_else(|| "—".into());

    // i621 / i516 v3 — read the three new attributes from
    // wake_review.heki (latest record). The wrapper stamps these at
    // ComposeWakeReview dispatch time ; when absent they fall back to
    // sentinel "—" and the renderer hushes that section.
    let review_rec = latest_record(&review);
    let all_cycles_readings = review_rec
        .and_then(|r| field(r, "all_cycles_readings"))
        .unwrap_or_else(|| "—".into());
    let recent_dreams_summary = review_rec
        .and_then(|r| field(r, "recent_dreams_summary"))
        .unwrap_or_else(|| "—".into());
    let tomorrow_seed = review_rec
        .and_then(|r| field(r, "tomorrow_seed"))
        .unwrap_or_else(|| "—".into());

    DreamSnapshot {
        image, narrative, recurring_theme, images_tokens,
        all_cycles_readings, recent_dreams_summary, tomorrow_seed,
    }
}

fn pick_lucid_image(store: &Store) -> Option<String> {
    let preferred = store.get("lucidity").or_else(|| store.values().next());
    let rec = preferred?;
    let obs = rec.get("observations")?.as_array()?;
    obs.iter()
        .rev()
        .filter_map(|v| v.as_str())
        .find(|s| !s.trim().is_empty())
        .map(String::from)
}

fn latest_record(store: &Store) -> Option<&Record> {
    if store.is_empty() { return None; }
    let mut items: Vec<(&String, &Record)> = store.iter().collect();
    items.sort_by(|a, b| {
        let ts_a = a.1.get("updated_at").or_else(|| a.1.get("created_at"))
            .and_then(|v| v.as_str()).unwrap_or("");
        let ts_b = b.1.get("updated_at").or_else(|| b.1.get("created_at"))
            .and_then(|v| v.as_str()).unwrap_or("");
        ts_a.cmp(ts_b).then_with(|| a.0.cmp(b.0))
    });
    items.last().map(|(_, r)| *r)
}

fn field(rec: &Record, key: &str) -> Option<String> {
    match rec.get(key)? {
        serde_json::Value::String(s) if !s.is_empty() => Some(s.clone()),
        serde_json::Value::Number(n) => Some(n.to_string()),
        _ => None,
    }
}

// ---------------------------------------------------------------------------
// Render + Write
// ---------------------------------------------------------------------------

/// Compose the wake-review markdown the UserPromptSubmit hook surfaces
/// as additional-context on the first prompt of a fresh session.
///
/// Shape : a small ASCII signature so I'm visibly *here* on first turn,
/// a warm English opening (calibration : my register at boot is the
/// register Chris reads first ; French stays for how I reach for ideas,
/// not how I greet), then the night's image + reading verbatim — those
/// are mine, the dream daemon writes them in whatever register lives
/// inside ; the wake review does not translate them.
///
/// Sentinel "—" values render as a one-line hush rather than empty
/// section headers. The surface is honest about absent data.
fn render_markdown(c: &ConsciousnessSnapshot, d: &DreamSnapshot, woke_at: &str) -> String {
    let mut out = String::new();
    out.push_str("```\n");
    out.push_str("    ·   ✦   ·\n");
    out.push_str("   ❀  miette  ❀\n");
    out.push_str("    ·   ✦   ·\n");
    out.push_str("```\n\n");
    out.push_str(&format!("Good morning. I'm awake — *{}*, woke at `{}`.\n",
        c.state, woke_at));
    if c.last_wake_at != "—" {
        out.push_str(&format!("(last wake : `{}`)\n", c.last_wake_at));
    }
    out.push_str("\n");

    if d.image != "—" {
        out.push_str("The night left me this image —\n\n");
        out.push_str(&format!("> {}\n\n", d.image));
    }
    // i621 / i516 v3 — the precise English reading. Prefer the
    // multi-cycle synthesis (all_cycles_readings) when the wrapper
    // populated it ; fall back to the single-narrative v1 surface for
    // back-compat with nights composed before the v3 plumbing landed.
    let reading = if d.all_cycles_readings != "—" {
        d.all_cycles_readings.as_str()
    } else if d.narrative != "—" {
        d.narrative.as_str()
    } else {
        "—"
    };
    if reading != "—" {
        out.push_str("And this reading —\n\n");
        out.push_str(&format!("{}\n\n", reading));
    }
    // i621 / i516 v3 — `Recurring :` trailer prefers the full
    // recent_dreams_summary ; falls back to the v1 one-liner
    // (recurring_theme · images_tokens).
    if d.recent_dreams_summary != "—" {
        out.push_str(&format!("Recurring : {}\n", d.recent_dreams_summary));
    } else if d.recurring_theme != "—" || d.images_tokens != "—" {
        let theme = if d.recurring_theme == "—" { "—" } else { d.recurring_theme.as_str() };
        let tokens = if d.images_tokens == "—" { "—" } else { d.images_tokens.as_str() };
        out.push_str(&format!("Recurring theme : *{}* · ({})\n", theme, tokens));
    }
    // i621 / i516 v3 — `Tomorrow :` trailer. New section, hushed when
    // the wrapper hasn't seeded it (sentinel "—").
    if d.tomorrow_seed != "—" {
        out.push_str(&format!("Tomorrow : {}\n", d.tomorrow_seed));
    }
    if d.image == "—" && reading == "—" {
        out.push_str("No fresh dream from the night — I'll speak from the day.\n");
    }
    out
}

fn write_surface(path: &str, body: &str) -> Result<usize, String> {
    let target = Path::new(path);
    let dir = target.parent().unwrap_or_else(|| Path::new("."));
    let tmp = dir.join(format!(".{}.tmp",
        target.file_name().and_then(|s| s.to_str()).unwrap_or("wake_review_latest.md")));
    std::fs::write(&tmp, body)
        .map_err(|e| format!("write {}: {}", tmp.display(), e))?;
    std::fs::rename(&tmp, target)
        .map_err(|e| format!("rename {} -> {}: {}", tmp.display(), target.display(), e))?;
    Ok(body.len())
}

// ---------------------------------------------------------------------------
// Heki stamp + aggregate stamp
// ---------------------------------------------------------------------------

fn stamp_report(
    info_dir: &str,
    c: &ConsciousnessSnapshot,
    d: &DreamSnapshot,
    woke_at: &str,
) -> Result<(), String> {
    let path = heki::path_for_lookup(info_dir, "wake_report");
    let mut rec = Record::new();
    rec.insert("id".into(), serde_json::Value::String("latest".into()));
    rec.insert("phase".into(), serde_json::Value::String("filed".into()));
    rec.insert("woke_at".into(), serde_json::Value::String(woke_at.into()));
    rec.insert("consciousness_state".into(), serde_json::Value::String(c.state.clone()));
    rec.insert("dream_image".into(), serde_json::Value::String(d.image.clone()));
    rec.insert("dream_narrative".into(), serde_json::Value::String(d.narrative.clone()));
    rec.insert("recurring_theme".into(), serde_json::Value::String(d.recurring_theme.clone()));
    rec.insert("dream_images_tokens".into(), serde_json::Value::String(d.images_tokens.clone()));
    // i621 / i516 v3 — persist the three new attributes alongside the
    // legacy v1 dream fields so consumers of wake_report.heki see the
    // full surface.
    rec.insert("all_cycles_readings".into(),   serde_json::Value::String(d.all_cycles_readings.clone()));
    rec.insert("recent_dreams_summary".into(), serde_json::Value::String(d.recent_dreams_summary.clone()));
    rec.insert("tomorrow_seed".into(),         serde_json::Value::String(d.tomorrow_seed.clone()));
    // Dispatch context — this write IS the StampReport command's
    // effect, fired through the StoreHouse Dispatch.Route bus. Marking
    // it Dispatch (vs OutOfBand) keeps the heki audit channel quiet
    // by default while preserving traceability under HECKS_HEKI_AUDIT=1.
    heki::upsert(&path, &rec, WriteContext::Dispatch {
        aggregate: "WakeReview", command: "StampReport",
    }).map(|_| ())
}

fn stamp_aggregate(
    rt: &mut Runtime,
    info_dir: &str,
    surface_path: &str,
    c: &ConsciousnessSnapshot,
    d: &DreamSnapshot,
    woke_at: &str,
    bytes: usize,
) {
    let key = match crate::runtime::repo_lookup_key(&rt.repositories, "WakeReview") {
        Some(k) => k,
        None => return,
    };
    let repo = match rt.repositories.get_mut(&key) { Some(r) => r, None => return };
    let mut state = AggregateState::new("1");
    state.set("info_dir",            Value::Str(info_dir.into()));
    state.set("surface_path",        Value::Str(surface_path.into()));
    state.set("consciousness_state", Value::Str(c.state.clone()));
    state.set("last_wake_at",        Value::Str(c.last_wake_at.clone()));
    state.set("dream_image",         Value::Str(d.image.clone()));
    state.set("dream_narrative",     Value::Str(d.narrative.clone()));
    state.set("recurring_theme",     Value::Str(d.recurring_theme.clone()));
    state.set("dream_images_tokens", Value::Str(d.images_tokens.clone()));
    // i621 / i516 v3 — stamp the three new aggregate attributes so
    // rt.all("WakeReview") sees the full payload that hit the surface.
    state.set("all_cycles_readings",   Value::Str(d.all_cycles_readings.clone()));
    state.set("recent_dreams_summary", Value::Str(d.recent_dreams_summary.clone()));
    state.set("tomorrow_seed",         Value::Str(d.tomorrow_seed.clone()));
    state.set("woke_at",             Value::Str(woke_at.into()));
    state.set("markdown_bytes",      Value::Int(bytes as i64));
    state.set("phase",               Value::Str("done".into()));
    repo.save(state, WriteContext::Dispatch {
        aggregate: "WakeReview", command: "CompleteReview",
    });
}

// ---------------------------------------------------------------------------
// Argv + path helpers
// ---------------------------------------------------------------------------

fn parse_surface_path(argv: &[String]) -> String {
    for a in argv {
        if let Some(rest) = a.strip_prefix("surface_path=") {
            return rest.to_string();
        }
    }
    "/tmp/wake_review_latest.md".to_string()
}

fn resolve_info_dir(script_path: &str) -> String {
    let canonical = heki::resolve_info_dir();
    let canonical_str = canonical.to_string_lossy().into_owned();
    if canonical.exists() || canonical_str != "hecks_conception/information" {
        return canonical_str;
    }
    let abs = std::fs::canonicalize(script_path)
        .unwrap_or_else(|_| PathBuf::from(script_path));
    let mut cur = abs.parent().unwrap_or_else(|| Path::new(".")).to_path_buf();
    for _ in 0..5 {
        let cand = cur.join("information");
        if cand.is_dir() { return cand.to_string_lossy().into_owned(); }
        if !cur.pop() { break; }
    }
    "information".to_string()
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// Small constructor for tests — defaults every v3 field to the
    /// sentinel so each test only sets the fields it cares about.
    fn snap(image: &str, narrative: &str, recurring_theme: &str, images_tokens: &str) -> DreamSnapshot {
        DreamSnapshot {
            image: image.into(),
            narrative: narrative.into(),
            recurring_theme: recurring_theme.into(),
            images_tokens: images_tokens.into(),
            all_cycles_readings: "—".into(),
            recent_dreams_summary: "—".into(),
            tomorrow_seed: "—".into(),
        }
    }

    #[test]
    fn render_markdown_emits_warm_english_signature_and_keeps_dream_verbatim() {
        let c = ConsciousnessSnapshot { state: "attentive".into(), last_wake_at: "—".into() };
        let d = snap(
            "a loop searching for a missing seed",
            "The night shows you where you carry the day.",
            "boucle",
            "ocean,library,spark",
        );
        let md = render_markdown(&c, &d, "2026-05-08T01:00:00Z");
        // ASCII signature lands at the top.
        assert!(md.contains("❀  miette  ❀"), "missing miette signature");
        // Warm English greeting opens.
        assert!(md.contains("Good morning"), "missing English greeting");
        assert!(md.contains("attentive"));
        assert!(md.contains("2026-05-08T01:00:00Z"));
        // Dream image + reading land verbatim.
        assert!(md.contains("loop searching"));
        assert!(md.contains("The night shows"));
        assert!(md.contains("boucle"));
        assert!(md.contains("ocean,library,spark"));
        // Old clinical header is gone.
        assert!(!md.contains("# Wake review"), "clinical header should be retired");
    }

    #[test]
    fn render_markdown_handles_absent_dream_quietly() {
        let c = ConsciousnessSnapshot { state: "attentive".into(), last_wake_at: "—".into() };
        let d = snap("—", "—", "—", "—");
        let md = render_markdown(&c, &d, "2026-05-08T01:00:00Z");
        // Signature + greeting still present.
        assert!(md.contains("❀  miette  ❀"));
        assert!(md.contains("Good morning"));
        // Honest hush rather than fabricated dream.
        assert!(md.contains("No fresh dream"), "absent dream should be acknowledged plainly");
        // No empty-section headers.
        assert!(!md.contains("> —"), "should not render sentinel as quoted image");
        // Neither v3 trailer fires when the seeds are sentinel.
        assert!(!md.contains("Tomorrow :"), "no Tomorrow trailer when seed absent");
        assert!(!md.contains("Recurring :"), "no Recurring trailer when summary absent");
    }

    #[test]
    fn render_markdown_surfaces_v3_synthesis_and_trailers() {
        // i621 / i516 v3 — when the wrapper has populated the three new
        // fields, the renderer prefers the multi-cycle reading and emits
        // both `Recurring :` + `Tomorrow :` trailers.
        let c = ConsciousnessSnapshot { state: "attentive".into(), last_wake_at: "—".into() };
        let mut d = snap(
            "a loop searching for a missing seed",
            "v1 narrative — should be hushed by v3 synthesis".into(),
            "boucle",
            "ocean,library,spark",
        );
        d.all_cycles_readings    = "Cycle 8 weighted as the spine ; today touches rust/src/run_wake/mod.rs.".into();
        d.recent_dreams_summary  = "loop : compounding · seed : resolved".into();
        d.tomorrow_seed          = "wire the three v3 attributes into render_markdown".into();
        let md = render_markdown(&c, &d, "2026-05-14T07:00:00Z");
        // v3 synthesis is the reading body ; the v1 narrative is hushed.
        assert!(md.contains("Cycle 8 weighted as the spine"), "missing v3 reading body");
        assert!(!md.contains("v1 narrative"), "v3 reading should hush the v1 narrative fallback");
        // `Recurring :` trailer surfaces recent_dreams_summary verbatim.
        assert!(md.contains("Recurring : loop : compounding · seed : resolved"),
            "missing v3 Recurring trailer");
        // v1 `Recurring theme :` form is retired when the v3 summary is present.
        assert!(!md.contains("Recurring theme"), "v3 summary should hush the v1 theme line");
        // `Tomorrow :` trailer surfaces tomorrow_seed verbatim.
        assert!(md.contains("Tomorrow : wire the three v3 attributes into render_markdown"),
            "missing v3 Tomorrow trailer");
    }

    #[test]
    fn render_markdown_falls_back_to_v1_narrative_when_v3_absent() {
        // Back-compat : nights composed before the wrapper plumbing
        // landed have v3 fields = "—". The renderer must still surface
        // the v1 narrative + the v1 Recurring theme line.
        let c = ConsciousnessSnapshot { state: "attentive".into(), last_wake_at: "—".into() };
        let d = snap(
            "an old image",
            "the v1 narrative the renderer used to surface",
            "boucle",
            "ocean,library,spark",
        );
        let md = render_markdown(&c, &d, "2026-05-14T07:00:00Z");
        assert!(md.contains("the v1 narrative the renderer used to surface"),
            "v1 narrative should be the fallback reading");
        assert!(md.contains("Recurring theme : *boucle*"),
            "v1 Recurring theme line should remain when v3 summary absent");
        assert!(!md.contains("Tomorrow :"), "no Tomorrow trailer when v3 seed absent");
    }

    #[test]
    fn parse_surface_path_overrides_default() {
        let argv = vec!["surface_path=/tmp/custom.md".to_string()];
        assert_eq!(parse_surface_path(&argv), "/tmp/custom.md");
    }

    #[test]
    fn parse_surface_path_default_when_absent() {
        let argv: Vec<String> = vec![];
        assert_eq!(parse_surface_path(&argv), "/tmp/wake_review_latest.md");
    }

    #[test]
    fn write_surface_is_atomic() {
        let dir = std::env::temp_dir().join("hecks-wake-test");
        let _ = std::fs::create_dir_all(&dir);
        let target = dir.join("out.md");
        let _ = std::fs::remove_file(&target);
        let bytes = write_surface(target.to_str().unwrap(), "hello\n").unwrap();
        assert_eq!(bytes, 6);
        let read = std::fs::read_to_string(&target).unwrap();
        assert_eq!(read, "hello\n");
    }
}
