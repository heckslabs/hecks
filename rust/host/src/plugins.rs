//! Wasm plugins: queries a package answers with its own module (the IR's `plugins` key), the
//! same module the Ruby runtime runs. A plugin is a WASI command, like the kernel: one question
//! as JSON on stdin, `{"question", "args"}`, and one answer as JSON on stdout, `{"rows"}` or
//! `{"refused"}`. A `reference_to` argument reaches it as the state of the record it names, read
//! from current state here, so the plugin never reaches the store.
//!
//! The module rides in the IR (base64, with its SHA-256), so every deploy that ships the IR ships
//! the plugin; it is written once to a cache file named by its digest and compiled once, by
//! `wasm_runner`'s per-path cache.

use crate::store::Store;
use crate::{dispatch, wasm_runner};
use base64::Engine as _;
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

/// One question a plugin answers, and what the host needs to ask it.
#[derive(Debug, PartialEq, Eq)]
pub struct PluginQuery {
    pub adapter: String,
    pub question: String,
    /// Each `reference_to` argument, by name, with the qualified aggregate it names.
    pub references: Vec<(String, String)>,
    pub sha256: String,
}

/// The plugin that answers a qualified question, if the IR names one.
pub fn answering(domain_ir: Option<&Value>, question: &str) -> Option<PluginQuery> {
    let plugins = domain_ir?.get("plugins")?.as_array()?;
    plugins.iter().find_map(|plugin| {
        let query = plugin
            .get("queries")?
            .as_array()?
            .iter()
            .find(|q| q["question"] == question)?;
        let references = query
            .get("references")
            .and_then(|r| r.as_object())
            .map(|r| {
                r.iter()
                    .filter_map(|(arg, agg)| Some((arg.clone(), agg.as_str()?.to_string())))
                    .collect()
            })
            .unwrap_or_default();
        Some(PluginQuery {
            adapter: plugin.get("adapter")?.as_str()?.to_string(),
            question: question.to_string(),
            references,
            sha256: plugin.get("sha256")?.as_str()?.to_string(),
        })
    })
}

/// Asks the plugin, each referenced record replaced by its current state, and shapes the answer
/// as the kernel shapes a query's: rows on success, a refusal otherwise.
pub async fn answer(
    plugin: &PluginQuery,
    domain_ir: &Value,
    args: Value,
    store: &Store,
    wasm_path: &Path,
) -> Result<Value, String> {
    let module = module_path(domain_ir, plugin)?;
    let mut asked_with = args.as_object().cloned().unwrap_or_default();
    if !plugin.references.is_empty() {
        let current = dispatch::read(store, wasm_path)
            .await
            .map_err(|e| format!("{e:#}"))?;
        if let Err(missing) =
            resolve_references(&plugin.references, &current["instances"], &mut asked_with)
        {
            return Ok(refusal(&plugin.question, &args, "NotFound", &missing));
        }
    }
    let input = json!({ "question": plugin.question, "args": asked_with }).to_string();
    let output = tokio::task::spawn_blocking(move || wasm_runner::run(&module, &input))
        .await
        .map_err(|e| e.to_string())?
        .map_err(|e| format!("{} failed: {e:#}", plugin.adapter))?;
    let reply: Value = serde_json::from_str(&output).map_err(|e| {
        format!(
            "{} answered with text that is not JSON: {e}",
            plugin.adapter
        )
    })?;
    if let Some(rows) = reply.get("rows") {
        return Ok(json!({
            "instances": {},
            "events": [],
            "refusals": [],
            "queries": [{ "query": plugin.question, "args": args, "rows": rows }],
        }));
    }
    reply.get("refused").and_then(|r| r.as_str()).map_or_else(
        || {
            Err(format!(
                "{} answered {} with neither rows nor a refusal",
                plugin.adapter, plugin.question
            ))
        },
        |why| {
            let message = format!("{}: {why}", plugin.question);
            Ok(refusal(&plugin.question, &args, "PluginRefusal", &message))
        },
    )
}

/// Replaces each reference argument's id with the state of the record it names, its id beside
/// its fields, as the Ruby runtime hands it over.
///
/// @return Err naming the first reference whose record is not there
pub fn resolve_references(
    references: &[(String, String)],
    instances: &Value,
    args: &mut Map<String, Value>,
) -> Result<(), String> {
    for (argument, aggregate) in references {
        let Some(id) = args
            .get(argument)
            .and_then(|v| v.as_str())
            .map(str::to_string)
        else {
            continue;
        };
        let short = aggregate.rsplit("::").next().unwrap_or(aggregate);
        let mut state = instances
            .get(format!("{aggregate}#{id}"))
            .and_then(|s| s.as_object())
            .cloned()
            .ok_or_else(|| format!("{argument}: no {short} {id:?}"))?;
        state.insert("id".to_string(), Value::String(id));
        args.insert(argument.clone(), Value::Object(state));
    }
    Ok(())
}

fn refusal(question: &str, args: &Value, kind: &str, message: &str) -> Value {
    crate::query_step::refusal_result(question, args, kind, message)
}

/// Writes the plugin's module to a cache file named by its digest, once, and answers its path.
fn module_path(domain_ir: &Value, plugin: &PluginQuery) -> Result<PathBuf, String> {
    let path = plugin_dir().join(format!("{}.wasm", plugin.sha256));
    if path.exists() {
        return Ok(path);
    }
    let encoded = domain_ir["plugins"]
        .as_array()
        .and_then(|all| all.iter().find(|p| p["adapter"] == plugin.adapter.as_str()))
        .and_then(|p| p["module"].as_str())
        .ok_or_else(|| format!("the IR carries no module for {}", plugin.adapter))?;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .map_err(|e| format!("{}'s module is not base64: {e}", plugin.adapter))?;
    let digest = hex(&Sha256::digest(&bytes));
    if digest != plugin.sha256 {
        return Err(format!(
            "{}'s module does not match its digest",
            plugin.adapter
        ));
    }
    std::fs::create_dir_all(plugin_dir()).map_err(|e| e.to_string())?;
    // Written beside and renamed, so a concurrent reader never compiles a partial module.
    let partial = path.with_extension(format!("{}.partial", std::process::id()));
    std::fs::write(&partial, &bytes).map_err(|e| e.to_string())?;
    std::fs::rename(&partial, &path).map_err(|e| e.to_string())?;
    Ok(path)
}

/// Where modules are written, one file per digest.
fn plugin_dir() -> PathBuf {
    std::env::temp_dir().join("hecks-plugins")
}

fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    bytes.iter().fold(String::new(), |mut out, byte| {
        let _ = write!(out, "{byte:02x}");
        out
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const DOUBLER: &[u8] = include_bytes!("../../../spec/fixtures/wasm_plugin/doubler.wasm");

    fn ir() -> Value {
        json!({
            "plugins": [{
                "adapter": "Doubler",
                "runs": "doubler.wasm",
                "queries": [
                    { "question": "Pluginned::Ledger.Doubled", "references": { "entry": "Pluginned::Ledger" } },
                    { "question": "Pluginned::Ledger.Tripled", "references": {} }
                ],
                "sha256": hex(&Sha256::digest(DOUBLER)),
                "module": base64::engine::general_purpose::STANDARD.encode(DOUBLER),
            }]
        })
    }

    #[test]
    fn finds_the_plugin_answering_a_question_and_its_references() {
        let ir = ir();
        let found = answering(Some(&ir), "Pluginned::Ledger.Doubled").unwrap();
        assert_eq!(found.adapter, "Doubler");
        assert_eq!(
            found.references,
            vec![("entry".to_string(), "Pluginned::Ledger".to_string())]
        );
        assert!(answering(Some(&ir), "Pluginned::Ledger.Halved").is_none());
        assert!(answering(None, "Pluginned::Ledger.Doubled").is_none());
    }

    #[test]
    fn hands_a_reference_over_as_the_record_state_with_its_id() {
        let instances = json!({ "Pluginned::Ledger#house": { "name": { "value": "house" }, "note": { "value": "rent" } } });
        let mut args = json!({ "entry": "house", "amount": 21 })
            .as_object()
            .cloned()
            .unwrap();
        let references = vec![("entry".to_string(), "Pluginned::Ledger".to_string())];

        resolve_references(&references, &instances, &mut args).unwrap();

        assert_eq!(
            args["entry"],
            json!({ "name": { "value": "house" }, "note": { "value": "rent" }, "id": "house" })
        );
        let mut missing = json!({ "entry": "nowhere" }).as_object().cloned().unwrap();
        assert_eq!(
            resolve_references(&references, &instances, &mut missing),
            Err("entry: no Ledger \"nowhere\"".to_string())
        );
    }

    #[test]
    fn runs_the_same_module_the_ruby_runtime_runs() {
        let ir = ir();
        let plugin = answering(Some(&ir), "Pluginned::Ledger.Doubled").unwrap();
        let module = module_path(&ir, &plugin).unwrap();
        let input = json!({
            "question": "Pluginned::Ledger.Doubled",
            "args": { "amount": 21, "entry": { "note": { "value": "rent" }, "id": "house" } }
        });

        let output = wasm_runner::run(&module, &input.to_string()).unwrap();

        assert_eq!(
            serde_json::from_str::<Value>(&output).unwrap(),
            json!({ "rows": [{ "amount": 42, "note": "rent" }] })
        );
    }

    #[test]
    fn refuses_a_module_that_does_not_match_its_digest() {
        let mut ir = ir();
        ir["plugins"][0]["sha256"] = json!("0".repeat(64));
        let plugin = answering(Some(&ir), "Pluginned::Ledger.Doubled").unwrap();

        assert_eq!(
            module_path(&ir, &plugin),
            Err("Doubler's module does not match its digest".to_string())
        );
    }
}
