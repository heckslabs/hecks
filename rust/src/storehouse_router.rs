//! storehouse_router — phrase-to-bluebook lookup + route dispatch.
//!
//! Extracted from main.rs so `run.rs` (and other library code) can resolve
//! and dispatch storehouse phrases without depending on the binary's main().
//!
//! Public API:
//!   `StorehousePhrase`            — resolved bluebook target for one phrase
//!   `route(args)`                 — resolve phrase + run_script dispatch
//!   `resolve(phrase, conception)` — look up phrase in the conception tree
//!   `walk_phrases(conception)`    — collect every Aggregate.Command pair
//!   `conception_root()`           — resolve hecks_conception/ directory
//!   `info_dir()`                  — resolve HECKS_INFO / information/ dir
//!
//! Example:
//!   ```ignore
//!   use storehouse::storehouse_router;
//!   let exit = storehouse_router::route(&["Story.Execute".to_string(), "id=f1".to_string()]);
//!   ```

/// A resolved bluebook target — the output of phrase lookup.
/// Mirrors the shape in main.rs; moved here so library code can route.
#[derive(Debug, Clone)]
pub struct StorehousePhrase {
    pub phrase: String,
    pub domain_phrase: String,
    pub bluebook_path: String,
    pub aggregate: String,
    pub command: String,
}

/// Resolve a phrase (e.g. `"Plan::Story.Execute"` or `"Story.Execute"`)
/// then dispatch it via `run_script`. Mirrors `storehouse_route` in main.rs.
/// Returns the run_script exit code.
pub fn route(args: &[String]) -> i32 {
    let phrase = match args.first() {
        Some(p) => p.clone(),
        None => { eprintln!("storehouse route: missing phrase"); return 1; }
    };
    let conception = conception_root();
    let target = match resolve(&phrase, &conception) {
        Some(t) => t,
        None => {
            eprintln!("storehouse route: phrase '{}' not found in lexicon", phrase);
            return 4;
        }
    };
    let mut run_args: Vec<String> = vec![
        "storehouse".to_string(),
        "run".to_string(),
        target.bluebook_path.clone(),
        format!("entrypoint={}", target.command),
    ];
    for a in args.iter().skip(1) {
        run_args.push(a.clone());
    }
    let verbose = std::env::var("HECKS_STOREHOUSE_VERBOSE").ok().as_deref() == Some("1");
    if verbose {
        eprintln!("[storehouse] Dispatch.Route → {} ({})", target.phrase, target.bluebook_path);
    }
    let exit = crate::run::run_script(&run_args);
    if exit == 0 && verbose {
        eprintln!("[storehouse] Dispatched");
    }
    exit
}

/// Look up `phrase` in the conception tree. Supports two-segment
/// (`Aggregate.Command`) and three-segment (`Domain::Aggregate.Command`
/// stored as `Domain.Aggregate.Command`) forms.
pub fn resolve(phrase: &str, conception: &str) -> Option<StorehousePhrase> {
    let phrases = walk_phrases(conception);
    // Normalize the canonical FQN Domain::Aggregate.Command (the runtime's
    // form, e.g. step phrases) to the dotted Domain.Aggregate.Command the
    // lexicon stores as domain_phrase, so :: phrases resolve.
    let normalized = phrase.replace("::", ".");
    let segments: Vec<&str> = normalized.split('.').collect();
    if segments.len() == 2 {
        phrases.into_iter().find(|p| p.phrase == normalized)
    } else if segments.len() == 3 {
        phrases.into_iter().find(|p| p.domain_phrase == normalized)
    } else {
        None
    }
}

/// Walk every *.bluebook under the conception's bucket roots and collect
/// every Aggregate.Command pair as a `StorehousePhrase`. Mirrors
/// `storehouse_walk_phrases` in main.rs.
pub fn walk_phrases(conception: &str) -> Vec<StorehousePhrase> {
    let root = std::path::Path::new(conception);
    let hecks_root = crate::heki::repo_root();
    let mut out = Vec::new();
    collect_recursive(&root.join("aggregates"), &mut out);
    collect_recursive(&root.join("storehouse"), &mut out);
    if let Some(hroot) = hecks_root {
        for bucket in &["runtime", "codegen", "cli", "integrations", "tools", "discipline"] {
            collect_recursive(&hroot.join(bucket), &mut out);
        }
    }
    out
}

fn collect_recursive(dir: &std::path::Path, out: &mut Vec<StorehousePhrase>) {
    if !dir.is_dir() { return; }
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let p = entry.path();
            if p.is_dir() {
                collect_recursive(&p, out);
            } else if p.extension().map(|e| e == "bluebook").unwrap_or(false) {
                if let Ok(src) = std::fs::read_to_string(&p) {
                    let domain = crate::parser::parse(&src);
                    if domain.name.is_empty() { continue; }
                    let path_str = p.to_string_lossy().into_owned();
                    // The canonical runtime FQN uses the bluebook's CATEGORY
                    // (e.g. "plan" → "Plan"), not its bluebook NAME (e.g.
                    // "Story"). A use-case step phrase is `Plan::Story.Execute`
                    // → normalized to `Plan.Story.Execute`, so domain_phrase
                    // must lead with PascalCase(category) to ever match. Fall
                    // back to the bluebook name when no category is declared.
                    let domain_seg = domain.category.as_deref()
                        .map(pascal_case_segments)
                        .unwrap_or_else(|| domain.name.clone());
                    for agg in &domain.aggregates {
                        for cmd in &agg.commands {
                            out.push(StorehousePhrase {
                                phrase: format!("{}.{}", agg.name, cmd.name),
                                domain_phrase: format!("{}.{}.{}", domain_seg, agg.name, cmd.name),
                                bluebook_path: path_str.clone(),
                                aggregate: agg.name.clone(),
                                command: cmd.name.clone(),
                            });
                        }
                    }
                }
            }
        }
    }
}

/// PascalCase a category slug: split on `_`, capitalize each segment,
/// concatenate. `"plan" → "Plan"`, `"use_case" → "UseCase"`. The category
/// is the runtime's domain segment in a fully-qualified phrase
/// (`Plan::Story.Execute`), so the lexicon must build `domain_phrase` with
/// this form for FQN step phrases to resolve.
pub fn pascal_case_segments(slug: &str) -> String {
    slug.split('_')
        .filter(|s| !s.is_empty())
        .map(|word| {
            let mut chars = word.chars();
            match chars.next() {
                Some(first) => first.to_ascii_uppercase().to_string() + chars.as_str(),
                None => String::new(),
            }
        })
        .collect()
}

/// Resolve the conception root (`hecks_conception/` directory).
/// Resolution order: HECKS_CONCEPTION_DIR env → repo_root/hecks_conception →
/// ~/Projects/hecks/hecks_conception → `.` fallback.
pub fn conception_root() -> String {
    if let Ok(p) = std::env::var("HECKS_CONCEPTION_DIR") {
        if !p.is_empty() { return p; }
    }
    if let Some(root) = crate::heki::repo_root() {
        let conception = root.join("hecks_conception");
        if conception.is_dir() {
            return conception.to_string_lossy().into_owned();
        }
        return root.to_string_lossy().into_owned();
    }
    if let Ok(home) = std::env::var("HOME") {
        let fallback = format!("{}/Projects/hecks/hecks_conception", home);
        if std::path::Path::new(&fallback).is_dir() {
            return fallback;
        }
    }
    ".".into()
}

/// Resolve the HECKS_INFO / information/ directory used by heki stores.
/// Returns None only when the default path doesn't exist and HECKS_INFO
/// is not set (i.e. we can't meaningfully store).
pub fn info_dir() -> Option<String> {
    let canonical = crate::heki::resolve_info_dir();
    let s = canonical.to_string_lossy().into_owned();
    if canonical.exists() || s != "hecks_conception/information" {
        Some(s)
    } else {
        None
    }
}

/// Resolve the heki directory declared in the `.world` file adjacent to a
/// bluebook, falling back to the global `info_dir()`. Mirrors the
/// `find_world_heki_dir` logic from main.rs so `run.rs` can use the
/// world-declared path when projecting `StoryExecuted` use-case runs.
///
/// The `.world` file sits next to the bluebook's parent directory:
///   `aggregates/plan/story/story.bluebook` → world search in `aggregates/`
///   `aggregates/plan.bluebook`             → world search in `aggregates/`
pub fn world_heki_dir(bluebook_path: &str) -> Option<String> {
    let p = std::path::Path::new(bluebook_path);
    // Walk up two directories (file → parent → grandparent) to find the
    // .world file — mirrors read_world_heki_dir in main.rs.
    let grandparent = if p.is_dir() {
        p.parent()
    } else {
        p.parent().and_then(|d| d.parent())
    }?;
    let world_file = std::fs::read_dir(grandparent).ok()?
        .filter_map(|e| e.ok())
        .find(|e| e.path().extension().map_or(false, |ext| ext == "world"))?
        .path();
    let source = std::fs::read_to_string(&world_file).ok()?;
    let world = crate::world::parser::parse(&source);
    let dir_value = world.config_for("heki").and_then(|c| c.get("dir"))?;
    let world_dir = world_file.parent()?;
    let resolved = world_dir.join(dir_value);
    Some(std::fs::canonicalize(&resolved)
        .unwrap_or(resolved)
        .to_string_lossy()
        .into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pascal_case_single_word() {
        assert_eq!(pascal_case_segments("plan"), "Plan");
    }

    #[test]
    fn pascal_case_underscored() {
        assert_eq!(pascal_case_segments("use_case"), "UseCase");
    }

    #[test]
    fn pascal_case_empty_segments_skipped() {
        assert_eq!(pascal_case_segments("_a__b_"), "AB");
    }

    #[test]
    fn collect_builds_category_domain_phrase() {
        // A bluebook with category "plan" and a "Story" aggregate must
        // yield the FQN domain_phrase "Plan.Story.Execute" (the runtime's
        // canonical form, written `Plan::Story.Execute` in step phrases),
        // NOT the bluebook-name form "Story.Story.Execute".
        let dir = std::env::temp_dir().join(format!("hecks_router_test_{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let bb = dir.join("story.bluebook");
        std::fs::write(&bb,
            "Hecks.bluebook \"Story\" do\n  category \"plan\"\n  aggregate \"Story\", \"x\" do\n    command \"Execute\" do\n      emits \"StoryExecuted\"\n    end\n  end\nend\n").unwrap();
        let mut out = Vec::new();
        collect_recursive(&dir, &mut out);
        let _ = std::fs::remove_dir_all(&dir);
        let phrase = out.iter().find(|p| p.command == "Execute")
            .expect("Execute phrase collected");
        assert_eq!(phrase.domain_phrase, "Plan.Story.Execute");
        assert_eq!(phrase.phrase, "Story.Execute");
    }

    #[test]
    fn resolve_fqn_phrase_with_double_colon() {
        // `Plan::Story.Execute` (the runtime FQN) normalizes to
        // `Plan.Story.Execute` and resolves against the category-built
        // domain_phrase. This is the GAP-1 acceptance: a 3-segment FQN
        // step phrase resolves. Uses an isolated temp conception so the
        // test never depends on the live tree's contents.
        let root = std::env::temp_dir().join(format!("hecks_router_conc_{}", std::process::id()));
        let agg_dir = root.join("aggregates").join("plan").join("story");
        std::fs::create_dir_all(&agg_dir).unwrap();
        std::fs::write(agg_dir.join("story.bluebook"),
            "Hecks.bluebook \"Story\" do\n  category \"plan\"\n  aggregate \"Story\", \"x\" do\n    command \"Execute\" do\n      emits \"StoryExecuted\"\n    end\n  end\nend\n").unwrap();
        let conception = root.to_string_lossy().into_owned();
        let resolved = resolve("Plan::Story.Execute", &conception);
        let _ = std::fs::remove_dir_all(&root);
        let target = resolved.expect("Plan::Story.Execute resolves");
        assert_eq!(target.aggregate, "Story");
        assert_eq!(target.command, "Execute");
        assert_eq!(target.domain_phrase, "Plan.Story.Execute");
    }
}
