//! Integration tests for the new `hecks-life heki` query subcommands.
//!
//! Each test shells to the built binary against a tmp fixture .heki file,
//! so the exit-code / output contract is exercised end-to-end. Plus
//! byte-for-byte parity tests against the current `python3 -c` shapes
//! that Phase B will retire.
//!
//! [antibody-exempt: test coverage for the new subcommands]

use hecks_life::heki;
use serde_json::json;
use std::path::{Path, PathBuf};
use std::process::Command;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn binary() -> PathBuf {
    // Built by `cargo test` before these run — same profile.
    let mut p = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    p.push("target");
    p.push(if cfg!(debug_assertions) { "debug" } else { "release" });
    p.push("hecks-life");
    p
}

fn tmpdir() -> PathBuf {
    let d = std::env::temp_dir().join(format!("hq_{}_{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
    std::fs::create_dir_all(&d).unwrap();
    d
}

fn write_store(path: &Path, records: &[(&str, serde_json::Value)]) {
    let mut store: heki::Store = heki::Store::new();
    for (id, rec) in records {
        let obj = rec.as_object().expect("record must be an object");
        let mut r = heki::Record::new();
        r.insert("id".into(), json!(id));
        for (k, v) in obj { r.insert(k.clone(), v.clone()); }
        store.insert(id.to_string(), r);
    }
    heki::write(path.to_str().unwrap(), &store).unwrap();
}

fn run(args: &[&str]) -> (i32, String, String) {
    let out = Command::new(binary())
        .args(args)
        .output()
        .expect("binary should run");
    (
        out.status.code().unwrap_or(-1),
        String::from_utf8_lossy(&out.stdout).to_string(),
        String::from_utf8_lossy(&out.stderr).to_string(),
    )
}

fn sample_inbox(path: &Path) {
    write_store(path, &[
        ("a", json!({
            "ref": "i3", "priority": "high", "status": "queued",
            "posted_at": "2026-04-01T00:00:00Z", "created_at": "2026-04-01T00:00:00Z",
            "body": "third"
        })),
        ("b", json!({
            "ref": "i1", "priority": "medium", "status": "queued",
            "posted_at": "2026-04-01T00:00:01Z", "created_at": "2026-04-01T00:00:01Z",
            "body": "first"
        })),
        ("c", json!({
            "ref": "i2", "priority": "high", "status": "done",
            "posted_at": "2026-04-01T00:00:02Z", "created_at": "2026-04-01T00:00:02Z",
            "body": "second"
        })),
        ("d", json!({
            "ref": "i10", "priority": "medium", "status": "queued",
            "posted_at": "2026-04-01T00:00:03Z", "created_at": "2026-04-01T00:00:03Z",
            "body": "tenth"
        })),
    ]);
}

// ---------------------------------------------------------------------------
// `heki get`
// ---------------------------------------------------------------------------

#[test]
fn get_returns_scalar_field_value() {
    let dir = tmpdir();
    let f = dir.join("inbox.heki");
    sample_inbox(&f);
    let (rc, out, _) = run(&["heki", "get", f.to_str().unwrap(), "a", "ref"]);
    assert_eq!(rc, 0);
    assert_eq!(out.trim(), "i3");
}

#[test]
fn get_returns_json_without_field() {
    let dir = tmpdir();
    let f = dir.join("inbox.heki");
    sample_inbox(&f);
    let (rc, out, _) = run(&["heki", "get", f.to_str().unwrap(), "a"]);
    assert_eq!(rc, 0);
    assert!(out.contains("\"ref\""));
    assert!(out.contains("\"i3\""));
}

#[test]
fn get_unknown_field_exits_3() {
    let dir = tmpdir();
    let f = dir.join("inbox.heki");
    sample_inbox(&f);
    let (rc, _, _) = run(&["heki", "get", f.to_str().unwrap(), "a", "nope"]);
    assert_eq!(rc, 3);
}

#[test]
fn get_unknown_id_exits_1() {
    let dir = tmpdir();
    let f = dir.join("inbox.heki");
    sample_inbox(&f);
    let (rc, _, _) = run(&["heki", "get", f.to_str().unwrap(), "missing"]);
    assert_eq!(rc, 1);
}

// ---------------------------------------------------------------------------
// `heki list`
// ---------------------------------------------------------------------------

#[test]
fn list_filters_by_where_eq() {
    let dir = tmpdir();
    let f = dir.join("inbox.heki");
    sample_inbox(&f);
    let (rc, out, _) = run(&["heki", "list", f.to_str().unwrap(),
        "--where", "status=queued", "--fields", "ref", "--format", "tsv",
        "--order", "ref:numeric_ref"]);
    assert_eq!(rc, 0);
    let lines: Vec<_> = out.lines().collect();
    assert_eq!(lines, vec!["i1", "i3", "i10"]);
}

#[test]
fn list_respects_priority_enum_then_ref_numeric() {
    let dir = tmpdir();
    let f = dir.join("inbox.heki");
    sample_inbox(&f);
    let (rc, out, _) = run(&["heki", "list", f.to_str().unwrap(),
        "--where", "status=queued",
        "--order", "priority:enum=high,medium,normal,low",
        "--order", "ref:numeric_ref",
        "--fields", "ref,priority", "--format", "tsv"]);
    assert_eq!(rc, 0);
    let want = "i3\thigh\ni1\tmedium\ni10\tmedium\n";
    assert_eq!(out, want);
}

#[test]
fn list_kv_format_prints_key_equals_value() {
    let dir = tmpdir();
    let f = dir.join("inbox.heki");
    sample_inbox(&f);
    let (rc, out, _) = run(&["heki", "list", f.to_str().unwrap(),
        "--where", "ref=i1", "--fields", "ref,priority", "--format", "kv"]);
    assert_eq!(rc, 0);
    assert!(out.contains("ref=i1"));
    assert!(out.contains("priority=medium"));
}

#[test]
fn list_invalid_filter_exits_2() {
    let dir = tmpdir();
    let f = dir.join("inbox.heki");
    sample_inbox(&f);
    let (rc, _, _) = run(&["heki", "list", f.to_str().unwrap(), "--where", "bogus"]);
    assert_eq!(rc, 2);
}

// ---------------------------------------------------------------------------
// `heki count`
// ---------------------------------------------------------------------------

#[test]
fn count_returns_filtered_total() {
    let dir = tmpdir();
    let f = dir.join("inbox.heki");
    sample_inbox(&f);
    let (rc, out, _) = run(&["heki", "count", f.to_str().unwrap(), "--where", "status=queued"]);
    assert_eq!(rc, 0);
    assert_eq!(out.trim(), "3");
}

#[test]
fn count_with_no_filter_is_total() {
    let dir = tmpdir();
    let f = dir.join("inbox.heki");
    sample_inbox(&f);
    let (rc, out, _) = run(&["heki", "count", f.to_str().unwrap()]);
    assert_eq!(rc, 0);
    assert_eq!(out.trim(), "4");
}

// ---------------------------------------------------------------------------
// `heki next-ref`
// ---------------------------------------------------------------------------

#[test]
fn next_ref_advances_max() {
    let dir = tmpdir();
    let f = dir.join("inbox.heki");
    sample_inbox(&f);
    let (rc, out, _) = run(&["heki", "next-ref", f.to_str().unwrap()]);
    assert_eq!(rc, 0);
    assert_eq!(out.trim(), "i11");
}

#[test]
fn next_ref_on_empty_store_is_one() {
    let dir = tmpdir();
    let f = dir.join("empty.heki");
    write_store(&f, &[]);
    let (rc, out, _) = run(&["heki", "next-ref", f.to_str().unwrap()]);
    assert_eq!(rc, 0);
    assert_eq!(out.trim(), "i1");
}

#[test]
fn next_ref_honors_custom_prefix() {
    let dir = tmpdir();
    let f = dir.join("x.heki");
    write_store(&f, &[
        ("a", json!({ "tag": "x3", "created_at": "2026-01-01T00:00:00Z" })),
        ("b", json!({ "tag": "x7", "created_at": "2026-01-01T00:00:01Z" })),
    ]);
    let (rc, out, _) = run(&["heki", "next-ref", f.to_str().unwrap(),
        "--prefix", "x", "--field", "tag"]);
    assert_eq!(rc, 0);
    assert_eq!(out.trim(), "x8");
}

// ---------------------------------------------------------------------------
// `heki latest-field`
// ---------------------------------------------------------------------------

#[test]
fn latest_field_picks_latest_updated_at() {
    let dir = tmpdir();
    let f = dir.join("s.heki");
    // latest is the one with the most recent updated_at (per heki::latest).
    let mut store = heki::Store::new();
    let mut r1 = heki::Record::new();
    r1.insert("id".into(), json!("1"));
    r1.insert("state".into(), json!("asleep"));
    r1.insert("updated_at".into(), json!("2026-04-01T00:00:00Z"));
    store.insert("1".into(), r1);
    let mut r2 = heki::Record::new();
    r2.insert("id".into(), json!("2"));
    r2.insert("state".into(), json!("awake"));
    r2.insert("updated_at".into(), json!("2026-04-01T01:00:00Z"));
    store.insert("2".into(), r2);
    heki::write(f.to_str().unwrap(), &store).unwrap();

    let (rc, out, _) = run(&["heki", "latest-field", f.to_str().unwrap(), "state"]);
    assert_eq!(rc, 0);
    assert_eq!(out.trim(), "awake");
}

#[test]
fn latest_field_unknown_exits_3() {
    let dir = tmpdir();
    let f = dir.join("s.heki");
    write_store(&f, &[("x", json!({"a": "b", "updated_at": "2026-01-01T00:00:00Z"}))]);
    let (rc, _, _) = run(&["heki", "latest-field", f.to_str().unwrap(), "missing"]);
    assert_eq!(rc, 3);
}

// ---------------------------------------------------------------------------
// `heki values`
// ---------------------------------------------------------------------------

#[test]
fn values_prints_one_per_line_ordered_by_created_at() {
    let dir = tmpdir();
    let f = dir.join("s.heki");
    sample_inbox(&f);
    let (rc, out, _) = run(&["heki", "values", f.to_str().unwrap(), "ref"]);
    assert_eq!(rc, 0);
    assert_eq!(out, "i3\ni1\ni2\ni10\n");
}

// ---------------------------------------------------------------------------
// `heki mark`
// ---------------------------------------------------------------------------

#[test]
fn mark_updates_matching_records_and_prints_count() {
    let dir = tmpdir();
    let f = dir.join("m.heki");
    write_store(&f, &[
        ("a", json!({"idea": "one",  "conceived": false, "created_at": "2026-01-01T00:00:00Z"})),
        ("b", json!({"idea": "two",  "conceived": false, "created_at": "2026-01-01T00:00:01Z"})),
        ("c", json!({"idea": "one",  "conceived": true,  "created_at": "2026-01-01T00:00:02Z"})),
    ]);
    let (rc, out, _) = run(&["heki", "mark", f.to_str().unwrap(),
        "--where", "idea=one", "--where", "conceived=false",
        "--set", "conceived=true"]);
    assert_eq!(rc, 0);
    assert_eq!(out.trim(), "1");

    // Verify via read.
    let (_, out, _) = run(&["heki", "list", f.to_str().unwrap(),
        "--where", "idea=one", "--fields", "id,conceived", "--format", "kv"]);
    assert!(out.contains("conceived=true"));
}

#[test]
fn mark_without_where_exits_2() {
    let dir = tmpdir();
    let f = dir.join("m.heki");
    sample_inbox(&f);
    let (rc, _, _) = run(&["heki", "mark", f.to_str().unwrap(), "--set", "x=y"]);
    assert_eq!(rc, 2);
}

// ---------------------------------------------------------------------------
// `heki seconds-since`
// ---------------------------------------------------------------------------

#[test]
fn seconds_since_parses_iso_8601() {
    let dir = tmpdir();
    let f = dir.join("hb.heki");
    write_store(&f, &[("x", json!({
        "updated_at": "2020-01-01T00:00:00Z",
        "created_at": "2020-01-01T00:00:00Z"
    }))]);
    let (rc, out, _) = run(&["heki", "seconds-since", f.to_str().unwrap(), "updated_at"]);
    assert_eq!(rc, 0);
    let n: i64 = out.trim().parse().expect("integer output");
    // Very loose bound — anything above 100M seconds means the parser worked.
    assert!(n > 100_000_000, "expected seconds-since > 100M, got {}", n);
}

// ---------------------------------------------------------------------------
// Byte-for-byte parity vs current python3 -c patterns
// ---------------------------------------------------------------------------

/// The `inbox.sh list queued` output layout. We reproduce it here via
/// `heki list --format tsv` + a shell-style printf line; then compare
/// to the python3 -c output from inbox.sh line 69-88 against the same
/// fixture.
#[test]
fn parity_inbox_list_queued_matches_python() {
    let dir = tmpdir();
    let f = dir.join("inbox.heki");
    sample_inbox(&f);

    // Phase B stub: my new subcommand + awk does what the python did.
    let (rc, out, _) = run(&["heki", "list", f.to_str().unwrap(),
        "--where", "status=queued",
        "--order", "priority:enum=high,medium,normal,low",
        "--order", "ref:numeric_ref",
        "--fields", "ref,priority,status,body",
        "--format", "tsv"]);
    assert_eq!(rc, 0);

    // Python equivalent (verbatim from inbox.sh lines 69-88 — just the
    // filter+sort+field extraction, not the padded formatting which is
    // a pure shell concern).
    let py_script = r#"
import json, struct, zlib, sys
with open(sys.argv[1], 'rb') as fh:
    data = fh.read()
assert data[:4] == b'HEKI'
store = json.loads(zlib.decompress(data[8:]).decode('utf-8'))
items = [v for v in store.values() if v.get('status') == 'queued']
order = {'high':0, 'medium':1, 'normal':2, 'low':3}
items.sort(key=lambda v: (
    order.get(v.get('priority','normal'), 9),
    int(v.get('ref','i999')[1:]) if v.get('ref','').startswith('i') else 999,
))
for v in items:
    print('\t'.join([
        v.get('ref',''), v.get('priority',''),
        v.get('status',''), v.get('body','').replace('\n',' ').replace('\t',' ')
    ]))
"#;
    let py = Command::new("python3")
        .args(["-c", py_script, f.to_str().unwrap()])
        .output().expect("python3 on PATH");
    assert!(py.status.success(), "python stderr: {}",
        String::from_utf8_lossy(&py.stderr));

    // `heki list --format tsv` matches the Python output line-for-line
    // except the Python replaces internal \n/\t with spaces. Our sample
    // body has none — so the outputs are byte-identical.
    let rust_out = out;
    let py_out = String::from_utf8(py.stdout).unwrap();
    assert_eq!(rust_out, py_out);
}

/// Parity with `statusline-command.sh` heartbeat `fatigue_state` extraction.
/// Python today: `json.load(sys.stdin).get('fatigue_state','')` on a
/// single-record store.
#[test]
fn parity_latest_field_matches_python_get() {
    let dir = tmpdir();
    let f = dir.join("hb.heki");
    let mut store = heki::Store::new();
    let mut r = heki::Record::new();
    r.insert("id".into(), json!("1"));
    r.insert("fatigue_state".into(), json!("alert"));
    r.insert("updated_at".into(), json!("2026-04-21T00:00:00Z"));
    store.insert("1".into(), r);
    heki::write(f.to_str().unwrap(), &store).unwrap();

    let (rc, rust_out, _) = run(&["heki", "latest-field", f.to_str().unwrap(), "fatigue_state"]);
    assert_eq!(rc, 0);

    let py_script = r#"
import json, struct, zlib, sys
with open(sys.argv[1], 'rb') as fh:
    data = fh.read()
store = json.loads(zlib.decompress(data[8:]).decode('utf-8'))
# latest = max updated_at
latest = max(store.values(), key=lambda v: v.get('updated_at',''))
print(latest.get('fatigue_state',''))
"#;
    let py = Command::new("python3")
        .args(["-c", py_script, f.to_str().unwrap()])
        .output().expect("python3 on PATH");
    assert!(py.status.success());

    let py_out = String::from_utf8(py.stdout).unwrap();
    assert_eq!(rust_out, py_out);
}

/// Parity with `mindstream.sh` idle-seconds computation (lines 100-111).
/// Python today: parse `updated_at` with datetime.fromisoformat, diff
/// against now, print int seconds.
#[test]
fn parity_seconds_since_matches_python_datetime() {
    let dir = tmpdir();
    let f = dir.join("hb.heki");
    let mut store = heki::Store::new();
    let mut r = heki::Record::new();
    r.insert("id".into(), json!("1"));
    r.insert("updated_at".into(), json!("2020-01-01T00:00:00Z"));
    store.insert("1".into(), r);
    heki::write(f.to_str().unwrap(), &store).unwrap();

    let (rc, rust_out, _) = run(&["heki", "seconds-since", f.to_str().unwrap(), "updated_at"]);
    assert_eq!(rc, 0);

    let py_script = r#"
import json, struct, zlib, sys
from datetime import datetime, timezone
with open(sys.argv[1], 'rb') as fh:
    data = fh.read()
store = json.loads(zlib.decompress(data[8:]).decode('utf-8'))
for v in store.values():
    ts = v.get('updated_at','')
    if ts:
        dt = datetime.fromisoformat(ts.replace('Z','+00:00'))
        print(int((datetime.now(timezone.utc) - dt).total_seconds()))
        break
"#;
    let py = Command::new("python3")
        .args(["-c", py_script, f.to_str().unwrap()])
        .output().expect("python3 on PATH");
    assert!(py.status.success());

    let py_secs: i64 = String::from_utf8(py.stdout).unwrap().trim().parse().unwrap();
    let rust_secs: i64 = rust_out.trim().parse().unwrap();
    // Allow 2s of slack — both are computed against `now` and one runs
    // after the other. The point is that both produce the same integer
    // seconds-since shape, not a millisecond-exact match.
    assert!((py_secs - rust_secs).abs() <= 2,
        "py={} rust={} (must be within 2s)", py_secs, rust_secs);
}
