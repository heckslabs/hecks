//! :web served-domain template resolution — a served domain ships and
//! serves its own `:web` template (Gap 1), even alongside `persisted_by`
//! binds in the same hecksagon (Gap 2 — confirmed a non-issue).
//!
//! Gap 1 was: `template_path` resolved against the hecks install root, so
//! a served domain's `template_path: "x.html"` 404'd. The fix stores the
//! RAW relative path on `WebRoute` and resolves it at render time —
//! `served_dir` first, `repo_root` fallback — so a served template serves
//! AND the framework's repo-root template (LivingDiagram) still resolves.

use std::collections::HashMap;
use std::cell::RefCell;
use storehouse::hecksagon_parser;
use storehouse::hecksagon_ir::Hecksagon;
use storehouse::runtime::Runtime;
use storehouse::server::web_adapter::WebRegistry;

fn empty_runtimes() -> HashMap<String, RefCell<Runtime>> { HashMap::new() }

/// Parse a hecksagon source into the keyed map `scan` expects.
fn hexmap(src: &str) -> HashMap<String, Hecksagon> {
    let hex = hecksagon_parser::parse(src);
    let mut m = HashMap::new();
    m.insert(hex.name.clone(), hex);
    m
}

/// Gap 1 + Gap 2 — a served-dir-only domain whose hecksagon carries BOTH
/// a `persisted_by` bind AND a keyword `adapter :web, template_path:`
/// serves the served-dir template with the file's contents.
#[test]
fn served_template_with_persisted_by_serves_from_served_dir() {
    let served = tempdir("web_served_a");
    std::fs::write(served.join("x.html"), "<h1>hello served x</h1>").unwrap();

    let hexes = hexmap(
        "Hecks.hecksagon \"Served\" do\n\
         \x20 Served::Thing.persisted_by(\"Heki\")\n\
         \x20 adapter :web,\n\
         \x20\x20\x20 get: \"/x\",\n\
         \x20\x20\x20 template_path: \"x.html\"\n\
         \x20 adapter :heki\n\
         end\n",
    );

    // Gap 2 guard — the :web route must register despite the binds.
    let repo_root = std::path::PathBuf::from("/nonexistent-repo-root");
    let registry = WebRegistry::scan(&hexes, &repo_root, &served);
    assert_eq!(registry.len(), 1, ":web route must register alongside binds");

    let (route, params) = registry.resolve("GET", "/x").expect("/x must match");
    let runtimes = empty_runtimes();
    let (ct, body) = storehouse::server::web_adapter::render(
        route, &params, &runtimes, &registry.served_dir, &registry.repo_root,
    ).expect("render must succeed from served_dir");
    assert_eq!(ct, "text/html");
    assert_eq!(body, "<h1>hello served x</h1>");
}

/// Framework case — a repo_root-relative template (LivingDiagram-shape)
/// is NOT in the served dir, so it must resolve via the repo_root
/// fallback. Guards against regressing `/diagram/...`.
#[test]
fn framework_template_resolves_via_repo_root_fallback() {
    let served = tempdir("web_served_b");      // no template here
    let repo = tempdir("web_repo_b");
    std::fs::create_dir_all(repo.join("runtime/ld")).unwrap();
    std::fs::write(repo.join("runtime/ld/page.template"), "<!DOCTYPE html>FRAMEWORK").unwrap();

    let hexes = hexmap(
        "Hecks.hecksagon \"Fw\" do\n\
         \x20 adapter :web,\n\
         \x20\x20\x20 get: \"/page\",\n\
         \x20\x20\x20 template_path: \"runtime/ld/page.template\"\n\
         end\n",
    );
    let registry = WebRegistry::scan(&hexes, &repo, &served);
    let (route, params) = registry.resolve("GET", "/page").expect("/page must match");
    let runtimes = empty_runtimes();
    let (_ct, body) = storehouse::server::web_adapter::render(
        route, &params, &runtimes, &registry.served_dir, &registry.repo_root,
    ).expect("render must fall back to repo_root");
    assert_eq!(body, "<!DOCTYPE html>FRAMEWORK");
}

/// Make a unique temp dir under the OS temp root.
fn tempdir(tag: &str) -> std::path::PathBuf {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
    let p = std::env::temp_dir().join(format!("storehouse_{}_{}", tag, nanos));
    std::fs::create_dir_all(&p).unwrap();
    p
}
