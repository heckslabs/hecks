//! Corpus loader — bluebook-discovery walk and organ-wins merge.
//!
//! Carved out of `main.rs` (core_runtime, shrink) into its own GROW
//! concern so the walk + dedupe logic can evolve alongside the
//! bluebook layout without fighting the shrink gate.  The contract is
//! the bluebook tree shape itself : organ-wins dedupe (i108/i143),
//! recursive discovery (i126), capability-sibling walk, repo-global
//! bucket walk (i118 Wave 1), and ../miette inclusion (i117 Round 4).
//!
//! The single public entry point is `load_combined_domain` — same
//! signature, same behaviour as before the extraction.
//!
//! Example:
//!   ```ignore
//!   use storehouse::corpus_loader::load_combined_domain;
//!   let domain = load_combined_domain("hecks_conception/aggregates");
//!   ```

use std::fs;

/// Load every `.bluebook` under `<agg_dir>/` (organs) and under sibling
/// `<agg_dir>/../capabilities/*/` (capability bluebooks) into a single
/// merged Domain. Closes inbox i108 — capability bluebooks were
/// previously skipped, so any aggregate declared in a capability bluebook
/// (e.g. Antibody.ExemptRegistry, MusingMint.Mint, ConsolidationSweep)
/// raised UnknownCommand on dispatch. Now they're auto-loaded alongside
/// the organ aggregates and dispatch resolves them through the standard
/// runtime path.
///
/// **Organ-wins dedupe.** When a capability bluebook re-declares an
/// aggregate already defined under aggregates/ (e.g. self_checkin.bluebook
/// declared a second `Heartbeat` without identified_by, which silently
/// overwrote body.bluebook's canonical one), the organ definition wins
/// and the capability copy is dropped. Capabilities can REFERENCE organ
/// aggregates ; redeclaration is a name conflict, not an extension.
pub fn load_combined_domain(agg_dir: &str) -> crate::ir::Domain {
    let mut combined = crate::ir::Domain {
        name: "Hecksagon".into(),
        category: None, vision: None,
        aggregates: vec![], policies: vec![],
        fixtures: vec![],
        entrypoint: None,
        sections: vec![],
        process_managers: vec![],
        cadences: vec![],
        block_grammars: vec![],
    };
    // Organ-wins dedupe (i108) — when two bluebooks declare the same
    // aggregate, the one closest to the dispatch root wins. Recursive
    // walk (i126) collects bluebooks with their depth ; we sort
    // shallowest-first and merge in that order so the deeper duplicate
    // is dropped by the existing any(existing.name == agg.name) check.
    let merge = |dom: crate::ir::Domain, c: &mut crate::ir::Domain| {
        for agg in dom.aggregates {
            // i143 — dedupe by (context, name), not name alone. i142
            // Tier 1 added Context.Aggregate.Command resolution but
            // didn't update this merge ; same-name-different-context
            // aggregates were silently dropped here, defeating the
            // dispatch path's ability to disambiguate. Now Boot.Identity,
            // Being.Identity, FirstBreath.Identity all survive merge ;
            // the resolver picks the right one by context. Same-name
            // SAME-context still dedupes (organ-wins, the i108 case
            // for capability-redeclaration of an organ aggregate).
            if c.aggregates.iter().any(|existing|
                existing.name == agg.name
                    && existing.context == agg.context
                    && existing.category == agg.category
            ) {
                continue;
            }
            c.aggregates.push(agg);
        }
        c.policies.extend(dom.policies);
        c.fixtures.extend(dom.fixtures);
        // i75-pulse-organs : process_managers + cadences + block_grammars
        // were dropped by the merge function — load_combined_domain only
        // ever surfaced the FIRST merged file's PMs, silently swallowing
        // every subsequent bluebook's process_manager declarations. The
        // Pulse / SleepCycle / Dream / Mind / Lucidity PMs that the
        // dream-study branch declares all hit this — registered in Ruby
        // specs (which load files individually), inert in `storehouse
        // run-loop` (which load_combined_domain's the directory). i75
        // closes this so the PMs reach PMEngine when run-loop boots.
        c.process_managers.extend(dom.process_managers);
        c.cadences.extend(dom.cadences);
        c.block_grammars.extend(dom.block_grammars);
    };

    // Recursive bluebook discovery (i126). Walk agg_dir at any depth.
    // Skip directories that are known not to contain domain content :
    // .git, target, information (heki stores), .claude (worktree
    // state), node_modules, generated, fixtures (test data),
    // snippets, behaviors (test fixtures, distinct from .behaviors
    // files which are picked up by their extension separately).
    // Symlinks not followed.
    fn collect_bluebooks(dir: &std::path::Path, depth: usize,
                          out: &mut Vec<(usize, std::path::PathBuf)>) {
        let Ok(entries) = fs::read_dir(dir) else { return };
        for entry in entries.flatten() {
            let p = entry.path();
            let name = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
            if matches!(name, ".git" | "target" | "information" | ".claude"
                | "node_modules" | "generated" | "fixtures" | "snippets"
                | "behaviors" | "behaviours") {
                continue;
            }
            if p.is_dir() {
                collect_bluebooks(&p, depth + 1, out);
            } else if p.extension().map(|e| e == "bluebook").unwrap_or(false) {
                out.push((depth, p));
            }
        }
    }

    let mut found: Vec<(usize, std::path::PathBuf)> = Vec::new();
    collect_bluebooks(std::path::Path::new(agg_dir), 0, &mut found);

    // Backward compat : the historic two-root model has organ
    // bluebooks under aggregates/ and capability shapes under sibling
    // capabilities/. The recursive walk above already finds children
    // of agg_dir ; we extend it to the sibling capabilities/ directory
    // when agg_dir's parent has one, so existing
    // `storehouse aggregates/ Cmd ...` invocations keep working.
    // Capability bluebooks land at depth 1 (a level below organs) so
    // the organ-wins dedupe rule is preserved.
    if let Some(parent) = std::path::Path::new(agg_dir).parent() {
        let cap_dir = parent.join("capabilities");
        if cap_dir.exists() && cap_dir != std::path::Path::new(agg_dir) {
            collect_bluebooks(&cap_dir, 1, &mut found);
        }
        // i117 Round 4 — Miette's body lives in the sibling miette/
        // repo (chrisyoung/miette) post-split. Walk ../miette as an
        // additional bluebook root at depth 1 so all of Miette's
        // self/mind/body/library/surface aggregates participate in
        // the same dispatch domain even though they live outside
        // hecks_conception. The pre-push behaviors gate already
        // scans this root ; the runtime now does too. Skipped
        // silently when the sibling repo isn't checked out (e.g. CI
        // running on hecks alone).
        //
        // Use heki::repo_root() (walks up from the executable) rather
        // than `parent.parent()` because `agg_dir` can be a relative
        // path (e.g. "hecks_conception/aggregates") whose parent.parent()
        // is empty/relative — `..` from there points to cwd's parent,
        // not the repo's parent. From a worktree under
        // `.claude/worktrees/agent-XXX/` that breaks reach to the real
        // `~/Projects/miette/`. The executable lives in the main
        // checkout's `storehouse/target/release/`, so walk-up from
        // current_exe finds the canonical hecks/ root. (i117 Round 4
        // follow-on : Chris's "no inbox row, just fix it" call after
        // the Wave 2 agent's worktree-path-resolution false-failure.)
        // Isolation gate (production) — the global roots below (Miette's
        // conception via ../miette and the repo's framework buckets) join
        // the dispatch domain ONLY when agg_dir is itself inside the hecks
        // repo, i.e. Miette dispatching against her own conception. A
        // standalone domain (a user's project, an isolated root) loads in
        // isolation : only its own bluebooks + sibling capabilities.
        // Without this gate every external dispatch dragged in Miette's
        // whole conception, so a foreign domain's events collided with her
        // policies (a demo `Greeted` fired memory's RecallOnGreet).
        let within_repo = std::fs::canonicalize(agg_dir).ok()
            .zip(crate::heki::repo_root()
                .and_then(|r| std::fs::canonicalize(&r).ok()))
            .map(|(a, r)| a.starts_with(&r))
            .unwrap_or(false);
        let canonical_miette = crate::heki::repo_root()
            .map(|r| r.join("../miette"))
            .filter(|p| p.is_dir())
            .and_then(|p| std::fs::canonicalize(&p).ok());
        if within_repo {
            if let Some(canonical) = canonical_miette {
                if canonical != std::path::Path::new(agg_dir) {
                    collect_bluebooks(&canonical, 1, &mut found);
                }
            }
        }
        // i118 Round 3 (capabilities reorg) — the 58 framework
        // capabilities that used to live under hecks_conception/capabilities/
        // are being lifted into top-level buckets at the hecks repo root :
        // runtime/, discipline/, codegen/, cli/, integrations/, tools/.
        // Wave 1 of the lift moves 33 caps ; codegen/ + statusline land in
        // Wave 2 (specializer-fed paths require golden regeneration). For
        // each known bucket directory at the repo root, collect bluebooks at
        // depth 1 so the dispatch domain still resolves them. The legacy
        // hecks_conception/capabilities/ walk above keeps working for caps
        // that haven't been lifted yet (the deferred codegen + statusline).
        if let Some(repo_root) = crate::heki::repo_root().filter(|_| within_repo) {
            // Runtime buckets only — chapters/ and bluebook/ are
            // descriptive (the framework's self-description and
            // language definition) and intentionally excluded from
            // the dispatch domain. Walking them in would surface
            // documentation-level Compile / Build / etc. commands
            // that collide with runtime-level same-named commands
            // (e.g. language/grammar's Compile gets shadowed by
            // chapters/cli.bluebook's Compile via depth-sort).
            for bucket in &["runtime", "discipline", "codegen", "cli",
                            "integrations", "tools"] {
                let bucket_dir = repo_root.join(bucket);
                if bucket_dir.is_dir() && bucket_dir != std::path::Path::new(agg_dir) {
                    collect_bluebooks(&bucket_dir, 1, &mut found);
                }
            }
        }
    }

    // Shallowest first — root-level bluebooks beat deeper ones on
    // name collision (i126). Within a depth, sort by path
    // lexicographically so the dedupe is reproducible across
    // filesystems (i141). Without the path tiebreaker, three
    // depth-0 bluebooks declaring the same aggregate (e.g. boot,
    // being, first_breath all declaring Identity) resolve by
    // fs::read_dir() inode order — which is undefined across
    // filesystems. The tiebreaker makes organ-wins deterministic.
    found.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(&b.1)));

    for (_, path) in found {
        if let Ok(source) = fs::read_to_string(&path) {
            merge(crate::parser::parse(&source), &mut combined);
        }
    }
    combined
}
