//! Tool harness — builds Ollama-native tool definitions
//!
//! Ollama's /api/chat supports tool calling natively. We define
//! tools as JSON function schemas. Qwen3 returns structured
//! tool_calls in the response. The engine executes them and
//! feeds results back as "tool" role messages.

use crate::tools::ToolSet;

/// Build Ollama-format tool definitions from the tool set.
pub fn ollama_tool_defs(tool_set: &ToolSet) -> Vec<serde_json::Value> {
    tool_set.tools.iter().map(|t| {
        serde_json::json!({
            "type": "function",
            "function": {
                "name": t.name,
                "description": t.description,
                "parameters": t.parameters.clone()
            }
        })
    }).collect()
}
