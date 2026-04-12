//! Persistence — JSON file storage for aggregate state
//!
//! Writes each aggregate record as a JSON file under
//! `{data_dir}/{AggregateType}/{id}.json`. Loads them
//! back on boot so state survives server restarts.
//!
//! Usage:
//!   persistence::save_to_disk(&data_dir, "Brand", &state);
//!   let records = persistence::load_from_disk(&data_dir, "Brand");

use super::{AggregateState, Value};
use std::collections::HashMap;
use std::path::Path;

/// Write one aggregate record to disk as JSON
pub fn save_to_disk(data_dir: &str, aggregate_type: &str, state: &AggregateState) {
    let dir = format!("{}/{}", data_dir, aggregate_type);
    if let Err(e) = std::fs::create_dir_all(&dir) {
        eprintln!("persistence: cannot create {}: {}", dir, e);
        return;
    }
    let path = format!("{}/{}.json", dir, state.id);
    let json = serialize_state(state);
    if let Err(e) = std::fs::write(&path, json) {
        eprintln!("persistence: cannot write {}: {}", path, e);
    }
}

/// Load all aggregate records for a type from disk
pub fn load_from_disk(data_dir: &str, aggregate_type: &str) -> Vec<AggregateState> {
    let dir = format!("{}/{}", data_dir, aggregate_type);
    let path = Path::new(&dir);
    if !path.exists() {
        return vec![];
    }
    let entries = match std::fs::read_dir(path) {
        Ok(e) => e,
        Err(_) => return vec![],
    };
    let mut records = vec![];
    for entry in entries.flatten() {
        let file_path = entry.path();
        if file_path.extension().map(|e| e == "json").unwrap_or(false) {
            if let Ok(content) = std::fs::read_to_string(&file_path) {
                if let Some(state) = deserialize_state(&content) {
                    records.push(state);
                }
            }
        }
    }
    records
}

fn serialize_state(state: &AggregateState) -> String {
    let mut pairs = vec![format!(r#""id":{}"#, json_string(&state.id))];
    let mut keys: Vec<&String> = state.fields.keys().collect();
    keys.sort();
    for key in keys {
        let val = &state.fields[key];
        pairs.push(format!(r#"{}:{}"#, json_string(key), serialize_value(val)));
    }
    format!("{{{}}}", pairs.join(","))
}

fn serialize_value(val: &Value) -> String {
    match val {
        Value::Str(s) => json_string(s),
        Value::Int(n) => n.to_string(),
        Value::Bool(b) => b.to_string(),
        Value::Null => "null".to_string(),
        Value::List(items) => {
            let parts: Vec<String> = items.iter().map(serialize_value).collect();
            format!("[{}]", parts.join(","))
        }
        Value::Map(m) => {
            let mut keys: Vec<&String> = m.keys().collect();
            keys.sort();
            let parts: Vec<String> = keys
                .iter()
                .map(|k| format!("{}:{}", json_string(k), serialize_value(&m[*k])))
                .collect();
            format!("{{{}}}", parts.join(","))
        }
    }
}

fn json_string(s: &str) -> String {
    let e = s.replace('\\', "\\\\").replace('"', "\\\"")
        .replace('\n', "\\n").replace('\r', "\\r").replace('\t', "\\t");
    format!(r#""{}""#, e)
}

fn deserialize_state(json: &str) -> Option<AggregateState> {
    let map = parse_object(json.trim())?;
    let id = match map.get("id")? { Value::Str(s) => s.clone(), _ => return None };
    let mut state = AggregateState::new(&id);
    for (k, v) in map { if k != "id" { state.set(&k, v); } }
    Some(state)
}

fn parse_object(s: &str) -> Option<HashMap<String, Value>> {
    let s = s.trim();
    if !s.starts_with('{') || !s.ends_with('}') {
        return None;
    }
    let inner = &s[1..s.len() - 1];
    let mut map = HashMap::new();
    let pairs = split_top_level(inner, ',');
    for pair in pairs {
        let pair = pair.trim();
        if pair.is_empty() { continue; }
        let colon = find_colon_after_key(pair)?;
        let key = parse_string_value(pair[..colon].trim())?;
        let val = parse_value(pair[colon + 1..].trim())?;
        map.insert(key, val);
    }
    Some(map)
}

fn find_colon_after_key(s: &str) -> Option<usize> {
    let s = s.trim();
    if !s.starts_with('"') { return None; }
    let end_quote = find_end_quote(s, 1)?;
    let rest = &s[end_quote + 1..];
    let colon_offset = rest.find(':')?;
    Some(end_quote + 1 + colon_offset)
}

fn parse_value(s: &str) -> Option<Value> {
    let s = s.trim();
    if s == "null" {
        Some(Value::Null)
    } else if s == "true" {
        Some(Value::Bool(true))
    } else if s == "false" {
        Some(Value::Bool(false))
    } else if s.starts_with('"') {
        parse_string_value(s).map(Value::Str)
    } else if s.starts_with('{') {
        parse_object(s).map(Value::Map)
    } else if s.starts_with('[') {
        parse_array(s).map(Value::List)
    } else {
        s.parse::<i64>().ok().map(Value::Int)
    }
}

fn parse_array(s: &str) -> Option<Vec<Value>> {
    let s = s.trim();
    if !s.starts_with('[') || !s.ends_with(']') { return None; }
    let inner = &s[1..s.len() - 1].trim();
    if inner.is_empty() { return Some(vec![]); }
    let items = split_top_level(inner, ',');
    items.iter().map(|item| parse_value(item.trim())).collect()
}

fn parse_string_value(s: &str) -> Option<String> {
    let s = s.trim();
    if s.len() < 2 || !s.starts_with('"') { return None; }
    let end = find_end_quote(s, 1)?;
    Some(s[1..end].replace("\\n", "\n").replace("\\r", "\r")
        .replace("\\t", "\t").replace("\\\"", "\"").replace("\\\\", "\\"))
}

fn find_end_quote(s: &str, start: usize) -> Option<usize> {
    let bytes = s.as_bytes();
    let mut i = start;
    while i < bytes.len() {
        if bytes[i] == b'\\' { i += 2; continue; }
        if bytes[i] == b'"' { return Some(i); }
        i += 1;
    }
    None
}

fn split_top_level(s: &str, sep: char) -> Vec<&str> {
    let mut parts = vec![];
    let mut depth = 0;
    let mut in_string = false;
    let mut start = 0;
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        if in_string {
            if b == b'\\' { i += 2; continue; }
            if b == b'"' { in_string = false; }
        } else {
            if b == b'"' { in_string = true; }
            else if b == b'{' || b == b'[' { depth += 1; }
            else if b == b'}' || b == b']' { depth -= 1; }
            else if b == sep as u8 && depth == 0 {
                parts.push(&s[start..i]);
                start = i + 1;
            }
        }
        i += 1;
    }
    if start < s.len() {
        parts.push(&s[start..]);
    }
    parts
}
