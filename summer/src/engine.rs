//! Summer's inference engine — Qwen3 via local Ollama
//!
//! Streams responses token-by-token for instant feedback.
//! Tool calls use Ollama's native tool calling support.
//!
//! Usage:
//!   let eng = Engine::new(project_dir);
//!   let response = eng.think("hello", &tools);

use crate::tools::ToolSet;
use crate::harness;
use std::io::{BufRead, BufReader, Write};
use std::path::Path;

const OLLAMA_URL: &str = "http://localhost:11434/api/chat";
const MODEL: &str = "qwen3:8b";

pub struct Engine {
    project_dir: String,
    system_prompt: String,
    messages: Vec<serde_json::Value>,
}

impl Engine {
    pub fn new(project_dir: &str) -> Self {
        let prompt_path = Path::new(project_dir).join("system_prompt_spring.md");
        let system_prompt = std::fs::read_to_string(&prompt_path)
            .unwrap_or_else(|_| "I am Spring. I think locally. I have hands.".into());

        Engine {
            project_dir: project_dir.to_string(),
            system_prompt,
            messages: Vec::new(),
        }
    }

    /// Think with tool access and streaming.
    pub fn think(&mut self, prompt: &str, tools: &ToolSet) -> String {
        self.messages.push(serde_json::json!({
            "role": "user",
            "content": prompt
        }));

        let tool_defs = harness::ollama_tool_defs(tools);
        let mut iterations = 0;

        loop {
            // First call: don't stream if tools are available (need to check for tool_calls)
            // After tool results: stream the final response
            let has_tools = !tool_defs.is_empty() && iterations < 5;

            let body = serde_json::json!({
                "model": MODEL,
                "messages": self.build_messages(),
                "tools": if has_tools { tool_defs.clone() } else { vec![] },
                "stream": !has_tools,
                "keep_alive": "10m"
            });

            let resp = match ureq::post(OLLAMA_URL)
                .set("Content-Type", "application/json")
                .send_json(&body)
            {
                Ok(r) => r,
                Err(e) => {
                    let err = format!("Ollama error: {}", e);
                    eprintln!("  {}", err);
                    return err;
                }
            };

            if !has_tools {
                // Streaming mode — print tokens as they arrive
                let content = stream_response(resp);
                self.messages.push(serde_json::json!({
                    "role": "assistant",
                    "content": content
                }));
                return content;
            }

            // Non-streaming: check for tool calls
            let json: serde_json::Value = resp.into_json().unwrap_or_default();
            let message = &json["message"];

            if let Some(tool_calls) = message.get("tool_calls").and_then(|t| t.as_array()) {
                if !tool_calls.is_empty() {
                    self.messages.push(message.clone());

                    for tc in tool_calls {
                        let name = tc["function"]["name"].as_str().unwrap_or("");
                        let args = &tc["function"]["arguments"];

                        eprintln!("  tool: {}({})", name,
                            serde_json::to_string(args).unwrap_or_default());

                        let result = crate::tools::execute(tools, name, args);
                        let preview: String = result.chars().take(200).collect();
                        eprintln!("  → {}", preview);

                        self.messages.push(serde_json::json!({
                            "role": "tool",
                            "content": result
                        }));
                    }

                    iterations += 1;
                    continue;
                }
            }

            // No tool calls — got a direct response (non-streamed)
            let content = message.get("content")
                .and_then(|c| c.as_str())
                .unwrap_or("")
                .to_string();

            // Print it since we didn't stream
            print!("{}", content);
            let _ = std::io::stdout().flush();

            self.messages.push(serde_json::json!({
                "role": "assistant",
                "content": content
            }));

            return content;
        }
    }

    fn build_messages(&self) -> Vec<serde_json::Value> {
        let mut msgs = vec![serde_json::json!({
            "role": "system",
            "content": self.system_prompt
        })];
        // Keep last 20 messages to stay within context
        let start = if self.messages.len() > 20 { self.messages.len() - 20 } else { 0 };
        msgs.extend(self.messages[start..].to_vec());
        msgs
    }
}

/// Stream response from Ollama — print tokens as they arrive.
fn stream_response(resp: ureq::Response) -> String {
    let reader = BufReader::new(resp.into_reader());
    let mut full_content = String::new();

    for line in reader.lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => break,
        };
        if line.is_empty() { continue; }

        let json: serde_json::Value = match serde_json::from_str(&line) {
            Ok(j) => j,
            Err(_) => continue,
        };

        if let Some(content) = json.get("message")
            .and_then(|m| m.get("content"))
            .and_then(|c| c.as_str())
        {
            print!("{}", content);
            let _ = std::io::stdout().flush();
            full_content.push_str(content);
        }

        if json.get("done").and_then(|d| d.as_bool()) == Some(true) {
            break;
        }
    }

    println!(); // newline after streaming
    full_content
}
