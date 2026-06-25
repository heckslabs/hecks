//! Seed loader — preloads aggregates from a dispatch script
//!
//! Reads a file of `dispatch CommandName key=value ...` lines
//! and executes them against the runtime at boot.
//!
//! Usage:
//!   seed_loader::load(&mut rt, "nursery/fixtures/seeds.txt");

use super::{Runtime, Value};
use std::collections::HashMap;

pub fn load(rt: &mut Runtime, path: &str) -> Result<usize, String> {
    let content = std::fs::read_to_string(path)
        .map_err(|e| format!("cannot read {}: {}", path, e))?;
    load_from_string(rt, &content)
}

pub fn load_from_string(rt: &mut Runtime, content: &str) -> Result<usize, String> {
    let mut count = 0;
    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some(rest) = line.strip_prefix("dispatch ") {
            let parts: Vec<&str> = rest.split_whitespace().collect();
            if parts.is_empty() {
                continue;
            }
            let command_name = parts[0];
            let attrs = parse_kv_attrs(&parts[1..]);
            rt.dispatch(command_name, attrs)
                .map_err(|e| format!("seed failed: {} — {}", line, e))?;
            count += 1;
        }
    }
    Ok(count)
}

fn parse_kv_attrs(pairs: &[&str]) -> HashMap<String, Value> {
    let mut attrs = HashMap::new();
    for kv in pairs {
        if let Some(eq) = kv.find('=') {
            let key = &kv[..eq];
            let val = &kv[eq + 1..];
            let value = if let Ok(n) = val.parse::<i64>() {
                Value::Int(n)
            } else if val == "true" || val == "false" {
                Value::Bool(val == "true")
            } else {
                Value::Str(val.to_string())
            };
            attrs.insert(key.to_string(), value);
        }
    }
    attrs
}
