//! Rust port of `Projector::Exporter#persistence_adapters`: the `adapters` key, the declarations
//! of the persistence adapters a domain binds, so `rust/host` looks adapters up in the IR instead
//! of a hard-coded list. Only declarations: a world's setting values never enter it.

use std::path::{Path, PathBuf};

use crate::json::Json;
use crate::subprocess;

// Never a source `.adapter`: build output and copies. Hidden directories are skipped too, as
// Ruby's `Dir.glob` skips them.
const SKIPPED_DIRS: [&str; 5] = ["target", "vendor", "node_modules", "tmp", ".git"];

/// The `adapters` array for `ir`: one entry per distinct adapter name in
/// `ir["persistence"]["aggregates"][].adapter` that an `.adapter` file under `directories`
/// declares, in name byte order. `hecks-parse adapter` reads all the files in one run.
///
/// # Errors
///
/// Returns the parser's failure, or a message naming an unreadable directory or output that
/// is not the JSON array `hecks-parse adapter` prints.
pub fn declarations(parser_bin: &Path, directories: &[PathBuf], ir: &Json) -> Result<Json, String> {
    let names = bound_names(ir);
    if names.is_empty() {
        return Ok(Json::Array(Vec::new()));
    }
    let files = files_under(directories)?;
    if files.is_empty() {
        return Ok(Json::Array(Vec::new()));
    }
    let mut args = vec!["adapter".to_string()];
    args.extend(files.iter().map(|p| p.to_string_lossy().to_string()));
    let arg_refs: Vec<&str> = args.iter().map(String::as_str).collect();
    let printed = subprocess::run_capture(&parser_bin.to_string_lossy(), &arg_refs)?;
    let parsed = Json::parse(&printed).map_err(|e| format!("parsing hecks-parse adapter: {e}"))?;
    Ok(select(&parsed, &names))
}

/// The distinct adapter names `ir`'s persistence block binds, in byte order.
pub fn bound_names(ir: &Json) -> Vec<String> {
    let aggregates = ir
        .get("persistence")
        .and_then(|persistence| persistence.get("aggregates"))
        .map_or(&[][..], Json::each);
    let mut names: Vec<String> = aggregates
        .iter()
        .filter_map(|aggregate| aggregate.get("adapter").and_then(Json::as_str))
        .map(str::to_string)
        .collect();
    names.sort();
    names.dedup();
    names
}

/// The entries of `declared` whose name is in `names`, the first of any repeated name
/// winning, in name byte order.
pub fn select(declared: &Json, names: &[String]) -> Json {
    let mut chosen: Vec<(String, Json)> = Vec::new();
    for adapter in declared.each() {
        let Some(name) = adapter.get("name").and_then(Json::as_str) else {
            continue;
        };
        if names.iter().any(|wanted| wanted == name) && !chosen.iter().any(|(n, _)| n == name) {
            chosen.push((name.to_string(), adapter.clone()));
        }
    }
    chosen.sort_by(|a, b| a.0.as_bytes().cmp(b.0.as_bytes()));
    Json::Array(chosen.into_iter().map(|(_, adapter)| adapter).collect())
}

/// Every `.adapter` file beneath `directories`, as absolute paths, unique and in byte order of
/// the path text. A directory that does not exist contributes none.
///
/// # Errors
///
/// Returns a message when a directory that exists cannot be read.
pub fn files_under(directories: &[PathBuf]) -> Result<Vec<PathBuf>, String> {
    let mut found = Vec::new();
    for directory in directories {
        let absolute = std::path::absolute(directory)
            .map_err(|e| format!("resolving {}: {e}", directory.display()))?;
        if absolute.is_dir() {
            walk(&absolute, &mut found)?;
        }
    }
    found.sort_by(|a, b| {
        a.to_string_lossy()
            .as_bytes()
            .cmp(b.to_string_lossy().as_bytes())
    });
    found.dedup();
    Ok(found)
}

fn walk(directory: &Path, found: &mut Vec<PathBuf>) -> Result<(), String> {
    let entries = std::fs::read_dir(directory)
        .map_err(|e| format!("reading {}: {e}", directory.display()))?;
    for entry in entries {
        let entry = entry.map_err(|e| format!("reading {}: {e}", directory.display()))?;
        let path = entry.path();
        let file_name = entry.file_name().to_string_lossy().to_string();
        let is_dir = entry.file_type().is_ok_and(|kind| kind.is_dir());
        if is_dir {
            if !file_name.starts_with('.') && !SKIPPED_DIRS.contains(&file_name.as_str()) {
                walk(&path, found)?;
            }
        } else if !file_name.starts_with('.') && file_name.ends_with(".adapter") && path.is_file() {
            found.push(path);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tmp::TempDir;

    fn parsed(text: &str) -> Json {
        Json::parse(text).expect("fixture json")
    }

    fn ir(adapters: &[&str]) -> Json {
        let rows: Vec<String> = adapters
            .iter()
            .map(|a| format!("{{\"name\":\"A\",\"storage_name\":\"a\",\"adapter\":\"{a}\"}}"))
            .collect();
        parsed(&format!(
            "{{\"persistence\":{{\"aggregates\":[{}]}}}}",
            rows.join(",")
        ))
    }

    #[test]
    fn bound_names_are_distinct_and_sorted() {
        let names = bound_names(&ir(&["Postgres", "Heki", "Postgres"]));
        assert_eq!(names, vec!["Heki".to_string(), "Postgres".to_string()]);
        assert!(bound_names(&parsed("{}")).is_empty());
    }

    #[test]
    fn select_keeps_bound_declarations_sorted_and_first_wins() {
        let declared = parsed(
            "[{\"name\":\"Postgres\",\"port\":\"persistence\",\"fields\":[],\"secrets\":[],\"defaults\":{}},\
              {\"name\":\"Unbound\",\"port\":null,\"fields\":[],\"secrets\":[],\"defaults\":{}},\
              {\"name\":\"Heki\",\"port\":\"persistence\",\"fields\":[\"dir\"],\"secrets\":[],\"defaults\":{\"dir\":\"data\"}},\
              {\"name\":\"Heki\",\"port\":null,\"fields\":[],\"secrets\":[],\"defaults\":{}}]",
        );
        let wanted = ["Heki", "Missing", "Postgres"].map(str::to_string);
        let chosen = select(&declared, &wanted);
        let names: Vec<&str> = chosen
            .each()
            .iter()
            .filter_map(|a| a.get("name").and_then(Json::as_str))
            .collect();
        assert_eq!(names, vec!["Heki", "Postgres"]);
        let heki_fields = chosen.each()[0].get("fields").map(|f| f.each().len());
        assert_eq!(heki_fields, Some(1));
    }

    #[test]
    fn files_under_skips_build_and_hidden_directories() {
        let dir = TempDir::new("adapters-pass").expect("temp dir");
        let root = dir.path();
        for relative in [
            "lib/a/heki.adapter",
            "lib/b/memory.adapter",
            "lib/target/skipped.adapter",
            "lib/vendor/skipped.adapter",
            "lib/node_modules/skipped.adapter",
            "lib/tmp/skipped.adapter",
            "lib/.hidden/skipped.adapter",
            "lib/a/notes.txt",
        ] {
            let path = root.join(relative);
            std::fs::create_dir_all(path.parent().expect("parent")).expect("mkdir");
            std::fs::write(&path, "").expect("write");
        }
        let scanned = [root.join("lib"), root.join("lib"), root.join("absent")];
        let found = files_under(&scanned).expect("scan");
        let relative: Vec<String> = found
            .iter()
            .map(|p| {
                let under = p.strip_prefix(root).expect("under root");
                under.to_string_lossy().to_string()
            })
            .collect();
        assert_eq!(relative, vec!["lib/a/heki.adapter", "lib/b/memory.adapter"]);
    }

    #[test]
    fn no_bound_adapter_means_an_empty_array_without_running_the_parser() {
        let none = declarations(Path::new("/no/such/parser"), &[], &ir(&[])).expect("empty");
        assert_eq!(none, Json::Array(Vec::new()));
    }
}
