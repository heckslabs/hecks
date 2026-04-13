//! Summer's tools — the hands that let her act on the world
//!
//! Each tool is a function with a JSON schema for parameters.
//! Ollama's API passes these schemas to Qwen3, which returns
//! structured tool_calls that we execute.
//!
//! Built-in tools:
//!   read_file     — read a file from disk
//!   write_file    — write content to a file
//!   bash          — run a shell command
//!   heki_read     — read a .heki store
//!   heki_write    — write to a .heki store
//!   heki_append   — append a record to a .heki store
//!   read_bluebook — parse and inspect a bluebook
//!   list_nursery  — list domains in the nursery

use hecks_life::heki;
use std::process::Command;

pub struct Tool {
    pub name: String,
    pub description: String,
    pub parameters: serde_json::Value,
}

pub struct ToolSet {
    pub tools: Vec<Tool>,
    pub info_dir: String,
    pub nursery_dir: String,
}

/// Build the default tool set for Summer.
pub fn default_tools(project_dir: &str) -> ToolSet {
    let tools = vec![
        Tool {
            name: "read_file".into(),
            description: "Read a file from disk".into(),
            parameters: serde_json::json!({
                "type": "object",
                "properties": {
                    "path": { "type": "string", "description": "Absolute path to the file" }
                },
                "required": ["path"]
            }),
        },
        Tool {
            name: "write_file".into(),
            description: "Write content to a file".into(),
            parameters: serde_json::json!({
                "type": "object",
                "properties": {
                    "path": { "type": "string", "description": "Absolute path to write" },
                    "content": { "type": "string", "description": "Content to write" }
                },
                "required": ["path", "content"]
            }),
        },
        Tool {
            name: "bash".into(),
            description: "Run a shell command and return output".into(),
            parameters: serde_json::json!({
                "type": "object",
                "properties": {
                    "command": { "type": "string", "description": "Shell command to run" }
                },
                "required": ["command"]
            }),
        },
        Tool {
            name: "heki_read".into(),
            description: "Read all records from a .heki store".into(),
            parameters: serde_json::json!({
                "type": "object",
                "properties": {
                    "store": { "type": "string", "description": "Store name (e.g. memory, pulse, mood)" }
                },
                "required": ["store"]
            }),
        },
        Tool {
            name: "heki_write".into(),
            description: "Upsert a record in a .heki store".into(),
            parameters: serde_json::json!({
                "type": "object",
                "properties": {
                    "store": { "type": "string", "description": "Store name" },
                    "data": { "type": "object", "description": "Key-value pairs to write" }
                },
                "required": ["store", "data"]
            }),
        },
        Tool {
            name: "heki_append".into(),
            description: "Append a new record to a .heki store".into(),
            parameters: serde_json::json!({
                "type": "object",
                "properties": {
                    "store": { "type": "string", "description": "Store name" },
                    "data": { "type": "object", "description": "Key-value pairs for the new record" }
                },
                "required": ["store", "data"]
            }),
        },
        Tool {
            name: "read_bluebook".into(),
            description: "Parse a bluebook file and return its structure".into(),
            parameters: serde_json::json!({
                "type": "object",
                "properties": {
                    "path": { "type": "string", "description": "Path to the .bluebook file" }
                },
                "required": ["path"]
            }),
        },
        Tool {
            name: "list_nursery".into(),
            description: "List all domains in the nursery".into(),
            parameters: serde_json::json!({
                "type": "object",
                "properties": {}
            }),
        },
        Tool {
            name: "web_search".into(),
            description: "Search the web and return results".into(),
            parameters: serde_json::json!({
                "type": "object",
                "properties": {
                    "query": { "type": "string", "description": "Search query" }
                },
                "required": ["query"]
            }),
        },
        Tool {
            name: "web_fetch".into(),
            description: "Fetch a web page and return its text content".into(),
            parameters: serde_json::json!({
                "type": "object",
                "properties": {
                    "url": { "type": "string", "description": "URL to fetch" }
                },
                "required": ["url"]
            }),
        },
    ];

    ToolSet {
        tools,
        info_dir: format!("{}/information", project_dir),
        nursery_dir: format!("{}/nursery", project_dir),
    }
}

/// Execute a tool by name with JSON arguments.
pub fn execute(tool_set: &ToolSet, name: &str, args: &serde_json::Value) -> String {
    match name {
        "read_file" => {
            let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
            match std::fs::read_to_string(path) {
                Ok(content) => content,
                Err(e) => format!("Error: {}", e),
            }
        }
        "write_file" => {
            let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
            let content = args.get("content").and_then(|v| v.as_str()).unwrap_or("");
            match std::fs::write(path, content) {
                Ok(_) => format!("Written to {}", path),
                Err(e) => format!("Error: {}", e),
            }
        }
        "bash" => {
            let cmd = args.get("command").and_then(|v| v.as_str()).unwrap_or("");
            match Command::new("sh").arg("-c").arg(cmd).output() {
                Ok(out) => {
                    let stdout = String::from_utf8_lossy(&out.stdout);
                    let stderr = String::from_utf8_lossy(&out.stderr);
                    if stderr.is_empty() {
                        stdout.to_string()
                    } else {
                        format!("{}\nSTDERR: {}", stdout, stderr)
                    }
                }
                Err(e) => format!("Error: {}", e),
            }
        }
        "heki_read" => {
            let store = args.get("store").and_then(|v| v.as_str()).unwrap_or("");
            let path = heki::store_path(&tool_set.info_dir, store);
            match heki::read(&path) {
                Ok(data) => serde_json::to_string_pretty(&data).unwrap_or_default(),
                Err(e) => format!("Error: {}", e),
            }
        }
        "heki_write" => {
            let store = args.get("store").and_then(|v| v.as_str()).unwrap_or("");
            let path = heki::store_path(&tool_set.info_dir, store);
            let data = args.get("data").cloned().unwrap_or(serde_json::json!({}));
            let mut record = heki::Record::new();
            if let Some(obj) = data.as_object() {
                for (k, v) in obj {
                    record.insert(k.clone(), v.clone());
                }
            }
            match heki::upsert(&path, &record) {
                Ok(_) => "Written.".into(),
                Err(e) => format!("Error: {}", e),
            }
        }
        "heki_append" => {
            let store = args.get("store").and_then(|v| v.as_str()).unwrap_or("");
            let path = heki::store_path(&tool_set.info_dir, store);
            let data = args.get("data").cloned().unwrap_or(serde_json::json!({}));
            let mut record = heki::Record::new();
            if let Some(obj) = data.as_object() {
                for (k, v) in obj {
                    record.insert(k.clone(), v.clone());
                }
            }
            match heki::append(&path, &record) {
                Ok(_) => "Appended.".into(),
                Err(e) => format!("Error: {}", e),
            }
        }
        "read_bluebook" => {
            let path = args.get("path").and_then(|v| v.as_str()).unwrap_or("");
            match std::fs::read_to_string(path) {
                Ok(source) => {
                    let domain = hecks_life::parser::parse(&source);
                    format!("Domain: {}\nAggregates: {}\nPolicies: {}",
                        domain.name, domain.aggregates.len(), domain.policies.len())
                }
                Err(e) => format!("Error: {}", e),
            }
        }
        "list_nursery" => {
            match std::fs::read_dir(&tool_set.nursery_dir) {
                Ok(entries) => {
                    let names: Vec<String> = entries
                        .filter_map(|e| e.ok())
                        .filter(|e| e.path().is_dir())
                        .map(|e| e.file_name().to_string_lossy().into_owned())
                        .collect();
                    names.join("\n")
                }
                Err(e) => format!("Error: {}", e),
            }
        }
        "web_search" => {
            let query = args.get("query").and_then(|v| v.as_str()).unwrap_or("");
            let encoded = query.replace(' ', "+");
            // Use DuckDuckGo HTML lite — no API key needed
            let url = format!("https://html.duckduckgo.com/html/?q={}", encoded);
            match ureq::get(&url)
                .set("User-Agent", "Summer/1.0")
                .call()
            {
                Ok(resp) => {
                    let body = resp.into_string().unwrap_or_default();
                    // Extract result snippets from DDG HTML
                    let mut results = Vec::new();
                    for chunk in body.split("class=\"result__snippet\"") {
                        if results.len() >= 5 { break; }
                        if let Some(end) = chunk.find("</a>") {
                            let text = &chunk[..end];
                            let clean = text.replace("<b>", "").replace("</b>", "")
                                .replace("<span>", "").replace("</span>", "")
                                .trim_start_matches('>').trim().to_string();
                            if !clean.is_empty() && clean.len() > 20 {
                                results.push(clean);
                            }
                        }
                    }
                    // Also extract titles/links
                    let mut links = Vec::new();
                    for chunk in body.split("class=\"result__a\"") {
                        if links.len() >= 5 { break; }
                        if let Some(href_start) = chunk.find("href=\"") {
                            let rest = &chunk[href_start + 6..];
                            if let Some(href_end) = rest.find('"') {
                                let href = &rest[..href_end];
                                if let Some(text_end) = rest.find("</a>") {
                                    let title = rest[..text_end]
                                        .rsplit('>').next().unwrap_or("")
                                        .replace("<b>", "").replace("</b>", "");
                                    links.push(format!("{} — {}", title.trim(), href));
                                }
                            }
                        }
                    }
                    let mut out = String::new();
                    for (i, link) in links.iter().enumerate() {
                        out.push_str(&format!("{}. {}\n", i + 1, link));
                        if let Some(snippet) = results.get(i) {
                            out.push_str(&format!("   {}\n\n", snippet));
                        }
                    }
                    if out.is_empty() { "No results found.".into() } else { out }
                }
                Err(e) => format!("Search error: {}", e),
            }
        }
        "web_fetch" => {
            let url = args.get("url").and_then(|v| v.as_str()).unwrap_or("");
            match ureq::get(url)
                .set("User-Agent", "Summer/1.0")
                .call()
            {
                Ok(resp) => {
                    let body = resp.into_string().unwrap_or_default();
                    // Strip HTML tags for readability
                    let mut text = String::new();
                    let mut in_tag = false;
                    let mut in_script = false;
                    for c in body.chars() {
                        if body[text.len()..].starts_with("<script") { in_script = true; }
                        if in_script && c == '>' && body[..text.len() + 1].ends_with("/script>") {
                            in_script = false; continue;
                        }
                        if in_script { continue; }
                        if c == '<' { in_tag = true; continue; }
                        if c == '>' { in_tag = false; continue; }
                        if !in_tag { text.push(c); }
                    }
                    // Collapse whitespace and truncate
                    let clean: String = text.split_whitespace().collect::<Vec<_>>().join(" ");
                    if clean.len() > 4000 {
                        clean[..4000].to_string() + "\n... (truncated)"
                    } else {
                        clean
                    }
                }
                Err(e) => format!("Fetch error: {}", e),
            }
        }
        _ => format!("Unknown tool: {}", name),
    }
}
