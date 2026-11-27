//! Claude Code's stream-json protocol, both ways: what a child prints and what it is sent.
//!
//! A child is started with `--input-format stream-json --output-format stream-json`, so every
//! line on its stdout is one JSON message and every line written to its stdin is one too. Control
//! requests and responses share those pipes: the harness sends `initialize` and `interrupt`, and
//! the child asks `can_use_tool` (a permission) and `mcp_message` (a call to the harness's own
//! in-process MCP server, which carries `send_message`).

use crate::json::{self, Value};

/// The name of the harness's in-process MCP server, as the child's `--mcp-config` declares it.
pub const MCP_SERVER: &str = "hecks";

/// The one tool the harness serves to every session.
pub const SEND_TOOL: &str = "send_message";

/// Claude Code's own cross-session tools, kept from every child so mail goes through Hecks.
pub const WITHHELD_TOOLS: &str = "SendMessage,ListAgents";

/// What one line from a child says.
#[derive(Debug, Clone, PartialEq)]
pub enum Heard {
    /// The child's first message: its own session id.
    Started { claude_session: String },
    /// The child asks the harness something and waits for the answer.
    Asked {
        request_id: String,
        request: Request,
    },
    /// The child answers a control request the harness sent (`initialize`, `interrupt`).
    Answered { request_id: String, ok: bool },
    /// A turn ended, with the model's last text.
    TurnEnded { is_error: bool, text: String },
    /// Anything else the child printed: assistant text, tool results, stream events.
    Said { kind: String },
}

/// A control request from the child.
#[derive(Debug, Clone, PartialEq)]
pub enum Request {
    /// May the model use this tool on this input?
    Permission { tool: String, input: Value },
    /// A JSON-RPC message for one of the in-process MCP servers.
    Mcp { server: String, message: Value },
    /// A request the harness has no answer for.
    Unknown { subtype: String },
}

/// Reads one line a child printed.
///
/// # Errors
///
/// Returns a message when the line is not JSON or names no `type`.
pub fn decode(line: &str) -> Result<Heard, String> {
    let value = json::parse(line)?;
    let kind = value
        .str_at("type")
        .ok_or("a line from the child names no type")?
        .to_string();
    Ok(match kind.as_str() {
        "system" if value.str_at("subtype") == Some("init") => Heard::Started {
            claude_session: value.str_at("session_id").unwrap_or_default().to_string(),
        },
        "control_request" => Heard::Asked {
            request_id: value.str_at("request_id").unwrap_or_default().to_string(),
            request: request(value.get("request").unwrap_or(&Value::Null)),
        },
        "control_response" => {
            let response = value.get("response").unwrap_or(&Value::Null);
            Heard::Answered {
                request_id: response
                    .str_at("request_id")
                    .unwrap_or_default()
                    .to_string(),
                ok: response.str_at("subtype") == Some("success"),
            }
        }
        "result" => Heard::TurnEnded {
            is_error: value
                .get("is_error")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            text: value.str_at("result").unwrap_or_default().to_string(),
        },
        _ => Heard::Said { kind },
    })
}

fn request(body: &Value) -> Request {
    match body.str_at("subtype") {
        Some("can_use_tool") => Request::Permission {
            tool: body.str_at("tool_name").unwrap_or_default().to_string(),
            input: body.get("input").cloned().unwrap_or(Value::Null),
        },
        Some("mcp_message") => Request::Mcp {
            server: body.str_at("server_name").unwrap_or_default().to_string(),
            message: body.get("message").cloned().unwrap_or(Value::Null),
        },
        other => Request::Unknown {
            subtype: other.unwrap_or_default().to_string(),
        },
    }
}

/// A user turn holding `text`, as the child reads it on stdin.
pub fn user_message(text: &str) -> String {
    Value::object(vec![
        ("type", Value::text("user")),
        (
            "message",
            Value::object(vec![
                ("role", Value::text("user")),
                ("content", Value::text(text)),
            ]),
        ),
        ("parent_tool_use_id", Value::Null),
        ("session_id", Value::text("default")),
    ])
    .to_json()
}

/// A control request from the harness to the child.
pub fn control_request(request_id: &str, subtype: &str) -> String {
    let mut body = vec![("subtype", Value::text(subtype))];
    if subtype == "initialize" {
        body.push(("hooks", Value::Null));
    }
    Value::object(vec![
        ("type", Value::text("control_request")),
        ("request_id", Value::text(request_id)),
        ("request", Value::object(body)),
    ])
    .to_json()
}

/// The harness's successful answer to the child's control request `request_id`.
pub fn control_success(request_id: &str, response: Value) -> String {
    Value::object(vec![
        ("type", Value::text("control_response")),
        (
            "response",
            Value::object(vec![
                ("subtype", Value::text("success")),
                ("request_id", Value::text(request_id)),
                ("response", response),
            ]),
        ),
    ])
    .to_json()
}

/// The harness's refusal of the child's control request `request_id`, with the reason.
pub fn control_error(request_id: &str, error: &str) -> String {
    Value::object(vec![
        ("type", Value::text("control_response")),
        (
            "response",
            Value::object(vec![
                ("subtype", Value::text("error")),
                ("request_id", Value::text(request_id)),
                ("error", Value::text(error)),
            ]),
        ),
    ])
    .to_json()
}

/// A permission refusal the model reads: the tool is not used and `reason` reaches it.
pub fn permission_denied(reason: &str) -> Value {
    Value::object(vec![
        ("behavior", Value::text("deny")),
        ("message", Value::text(reason)),
    ])
}

/// The arguments a Claude Code child is started with, after the program itself.
///
/// The child talks stream-json both ways, asks every permission over its pipes, serves the
/// harness's MCP server in process, and may use only `send_message` without asking.
pub fn claude_args(model: Option<&str>) -> Vec<String> {
    let mcp = Value::object(vec![(
        "mcpServers",
        Value::object(vec![(
            MCP_SERVER,
            Value::object(vec![
                ("type", Value::text("sdk")),
                ("name", Value::text(MCP_SERVER)),
            ]),
        )]),
    )]);
    let mut args: Vec<String> = [
        "-p",
        "--input-format",
        "stream-json",
        "--output-format",
        "stream-json",
        "--verbose",
        "--permission-prompt-tool",
        "stdio",
        "--strict-mcp-config",
    ]
    .iter()
    .map(ToString::to_string)
    .collect();
    args.push("--mcp-config".to_string());
    args.push(mcp.to_json());
    args.push("--allowedTools".to_string());
    args.push(format!("mcp__{MCP_SERVER}__{SEND_TOOL}"));
    args.push("--disallowedTools".to_string());
    args.push(WITHHELD_TOOLS.to_string());
    if let Some(model) = model.filter(|name| !name.is_empty()) {
        args.push(format!("--model={model}"));
    }
    args
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hears_the_session_id_on_init() {
        let heard =
            decode(r#"{"type":"system","subtype":"init","session_id":"abc","tools":[]}"#).unwrap();
        assert_eq!(
            heard,
            Heard::Started {
                claude_session: "abc".into()
            }
        );
    }

    #[test]
    fn hears_a_permission_ask() {
        let line = r#"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"rm x"}}}"#;
        let Heard::Asked {
            request_id,
            request: Request::Permission { tool, input },
        } = decode(line).unwrap()
        else {
            panic!("not a permission ask")
        };
        assert_eq!(
            (request_id.as_str(), tool.as_str(), input.str_at("command")),
            ("r1", "Bash", Some("rm x"))
        );
    }

    #[test]
    fn hears_an_mcp_call() {
        let line = r#"{"type":"control_request","request_id":"r2","request":{"subtype":"mcp_message","server_name":"hecks","message":{"jsonrpc":"2.0","id":1,"method":"tools/list"}}}"#;
        let Heard::Asked {
            request: Request::Mcp { server, message },
            ..
        } = decode(line).unwrap()
        else {
            panic!("not an mcp call")
        };
        assert_eq!(
            (server.as_str(), message.str_at("method")),
            ("hecks", Some("tools/list"))
        );
    }

    #[test]
    fn hears_the_end_of_a_turn() {
        let heard =
            decode(r#"{"type":"result","subtype":"success","is_error":false,"result":"done"}"#)
                .unwrap();
        assert_eq!(
            heard,
            Heard::TurnEnded {
                is_error: false,
                text: "done".into()
            }
        );
    }

    #[test]
    fn hears_an_answer_to_initialize() {
        let line = r#"{"type":"control_response","response":{"subtype":"success","request_id":"init-1","response":{}}}"#;
        assert_eq!(
            decode(line).unwrap(),
            Heard::Answered {
                request_id: "init-1".into(),
                ok: true
            }
        );
    }

    #[test]
    fn keeps_other_lines_by_their_type() {
        assert_eq!(
            decode(r#"{"type":"assistant","message":{}}"#).unwrap(),
            Heard::Said {
                kind: "assistant".into()
            }
        );
    }

    #[test]
    fn refuses_a_line_with_no_type() {
        assert!(decode(r#"{"message":{}}"#).is_err());
    }

    #[test]
    fn writes_a_user_turn_as_the_sdk_does() {
        assert_eq!(
            user_message("hi"),
            r#"{"type":"user","message":{"role":"user","content":"hi"},"parent_tool_use_id":null,"session_id":"default"}"#
        );
    }

    #[test]
    fn writes_initialize_with_no_hooks() {
        assert_eq!(
            control_request("init-1", "initialize"),
            r#"{"type":"control_request","request_id":"init-1","request":{"subtype":"initialize","hooks":null}}"#
        );
    }

    #[test]
    fn writes_a_permission_refusal() {
        assert_eq!(
            control_success("r1", permission_denied("no")),
            r#"{"type":"control_response","response":{"subtype":"success","request_id":"r1","response":{"behavior":"deny","message":"no"}}}"#
        );
    }

    #[test]
    fn starts_a_child_on_the_pipes_with_mail_through_hecks() {
        let args = claude_args(Some("haiku"));
        assert!(args
            .windows(2)
            .any(|pair| pair == ["--permission-prompt-tool", "stdio"]));
        assert!(args
            .windows(2)
            .any(|pair| pair == ["--disallowedTools", WITHHELD_TOOLS]));
        assert_eq!(args.last().map(String::as_str), Some("--model=haiku"));
    }

    #[test]
    fn passes_no_model_when_none_is_named() {
        assert!(!claude_args(None)
            .iter()
            .any(|arg| arg.starts_with("--model")));
    }
}
