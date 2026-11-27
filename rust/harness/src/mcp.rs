//! The harness's in-process MCP server: the one door a session has to the other sessions.
//!
//! It answers the JSON-RPC messages a child sends through `mcp_message` control requests. Its one
//! tool, `send_message`, does not deliver anything itself: it hands the message to the harness,
//! which tells the bluebook, and the bluebook's policy decides the delivery.

use crate::json::Value;
use crate::protocol::{MCP_SERVER, SEND_TOOL};

/// The MCP protocol version answered when the child names none.
pub const PROTOCOL_VERSION: &str = "2025-06-18";

/// A message a session asked to send, before anything is delivered.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Outgoing {
    /// The session name it is addressed to.
    pub to: String,
    /// What it says.
    pub text: String,
    /// The message it answers or relays, when the sender named one.
    pub about: Option<String>,
}

/// What the server makes of one JSON-RPC message.
#[derive(Debug, Clone, PartialEq)]
pub struct Handled {
    /// The JSON-RPC reply, carried back as the control response's `mcp_response`.
    pub reply: Value,
    /// The message to hand on, when the call was a good `send_message`.
    pub outgoing: Option<Outgoing>,
}

/// Answers one JSON-RPC message from a child.
pub fn handle(message: &Value) -> Handled {
    let id = message.get("id").cloned().unwrap_or(Value::Null);
    match message.str_at("method").unwrap_or_default() {
        "initialize" => answered(id, initialize(message)),
        "tools/list" => answered(
            id,
            Value::object(vec![("tools", Value::Array(vec![send_tool()]))]),
        ),
        "tools/call" => call(id, message.get("params").unwrap_or(&Value::Null)),
        method if method.starts_with("notifications/") => {
            answered(Value::Null, Value::object::<&str>(vec![]))
        }
        method => Handled {
            reply: error(
                id,
                -32601,
                &format!("the hecks server has no method {method}"),
            ),
            outgoing: None,
        },
    }
}

fn answered(id: Value, result: Value) -> Handled {
    Handled {
        reply: reply(id, "result", result),
        outgoing: None,
    }
}

fn reply(id: Value, key: &str, body: Value) -> Value {
    let mut pairs = vec![("jsonrpc", Value::text("2.0"))];
    if id != Value::Null {
        pairs.push(("id", id));
    }
    pairs.push((key, body));
    Value::object(pairs)
}

fn error(id: Value, code: i32, message: &str) -> Value {
    reply(
        id,
        "error",
        Value::object(vec![
            ("code", Value::Number(f64::from(code))),
            ("message", Value::text(message)),
        ]),
    )
}

fn initialize(message: &Value) -> Value {
    let asked = message
        .get("params")
        .and_then(|params| params.str_at("protocolVersion"));
    Value::object(vec![
        (
            "protocolVersion",
            Value::text(asked.unwrap_or(PROTOCOL_VERSION)),
        ),
        (
            "capabilities",
            Value::object(vec![("tools", Value::object::<&str>(vec![]))]),
        ),
        (
            "serverInfo",
            Value::object(vec![
                ("name", Value::text(MCP_SERVER)),
                ("version", Value::text(env!("CARGO_PKG_VERSION"))),
            ]),
        ),
    ])
}

fn send_tool() -> Value {
    let field = |meaning: &str| {
        Value::object(vec![
            ("type", Value::text("string")),
            ("description", Value::text(meaning)),
        ])
    };
    Value::object(vec![
        ("name", Value::text(SEND_TOOL)),
        (
            "description",
            Value::text("Send a message to another session by its name. The reply arrives later as a new message."),
        ),
        (
            "inputSchema",
            Value::object(vec![
                ("type", Value::text("object")),
                (
                    "properties",
                    Value::object(vec![
                        ("to", field("The name of the session to send to")),
                        ("text", field("What the message says")),
                        (
                            "about",
                            field("The id of the message this one answers or relays, such as coder-1"),
                        ),
                    ]),
                ),
                ("required", Value::Array(vec![Value::text("to"), Value::text("text")])),
            ]),
        ),
    ])
}

fn call(id: Value, params: &Value) -> Handled {
    let name = params.str_at("name").unwrap_or_default();
    if name != SEND_TOOL {
        return tool_result(
            id,
            &format!("the hecks server has no tool {name}"),
            true,
            None,
        );
    }
    let arguments = params.get("arguments").unwrap_or(&Value::Null);
    let to = arguments
        .str_at("to")
        .unwrap_or_default()
        .trim()
        .to_string();
    let text = arguments.str_at("text").unwrap_or_default().to_string();
    if to.is_empty() || text.trim().is_empty() {
        return tool_result(
            id,
            "a message names the session it goes to and says something",
            true,
            None,
        );
    }
    let about = arguments
        .str_at("about")
        .map(str::trim)
        .filter(|about| !about.is_empty())
        .map(ToString::to_string);
    let said = format!("Sent to {to}. The reply arrives as a new message.");
    tool_result(id, &said, false, Some(Outgoing { to, text, about }))
}

fn tool_result(id: Value, text: &str, is_error: bool, outgoing: Option<Outgoing>) -> Handled {
    let content = Value::Array(vec![Value::object(vec![
        ("type", Value::text("text")),
        ("text", Value::text(text)),
    ])]);
    let result = Value::object(vec![
        ("content", content),
        ("isError", Value::Bool(is_error)),
    ]);
    Handled {
        reply: reply(id, "result", result),
        outgoing,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::json::parse;

    fn handled(line: &str) -> Handled {
        handle(&parse(line).unwrap())
    }

    #[test]
    fn answers_initialize_with_the_version_asked() {
        let reply = handled(r#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#).reply;
        assert_eq!(
            reply
                .get("result")
                .and_then(|result| result.str_at("protocolVersion")),
            Some("2024-11-05")
        );
    }

    #[test]
    fn lists_send_message_as_the_only_tool() {
        let reply = handled(r#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#).reply;
        let tools = reply
            .get("result")
            .and_then(|result| result.get("tools"))
            .and_then(Value::as_array)
            .unwrap();
        assert_eq!(
            tools
                .iter()
                .filter_map(|tool| tool.str_at("name"))
                .collect::<Vec<_>>(),
            vec![SEND_TOOL]
        );
    }

    #[test]
    fn hands_on_a_good_send() {
        let line = r#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"send_message","arguments":{"to":"reviewer","text":"please review"}}}"#;
        assert_eq!(
            handled(line).outgoing,
            Some(Outgoing {
                to: "reviewer".into(),
                text: "please review".into(),
                about: None
            })
        );
    }

    #[test]
    fn carries_the_message_a_send_is_about() {
        let line = r#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"send_message","arguments":{"to":"coder","text":"yes","about":" coder-1 "}}}"#;
        assert_eq!(
            handled(line).outgoing.and_then(|outgoing| outgoing.about),
            Some("coder-1".to_string())
        );
    }

    #[test]
    fn refuses_a_send_with_no_recipient_and_hands_on_nothing() {
        let line = r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"send_message","arguments":{"to":" ","text":"x"}}}"#;
        let result = handled(line);
        assert_eq!(
            (
                result.outgoing,
                result
                    .reply
                    .get("result")
                    .and_then(|r| r.get("isError"))
                    .cloned()
            ),
            (None, Some(Value::Bool(true)))
        );
    }

    #[test]
    fn answers_an_unknown_method_with_a_jsonrpc_error() {
        let reply = handled(r#"{"jsonrpc":"2.0","id":4,"method":"resources/list"}"#).reply;
        assert_eq!(
            reply
                .get("error")
                .and_then(|error| error.get("code"))
                .and_then(Value::as_f64),
            Some(-32601.0)
        );
    }

    #[test]
    fn acknowledges_a_notification_with_an_empty_result() {
        assert_eq!(
            handled(r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
                .reply
                .to_json(),
            r#"{"jsonrpc":"2.0","result":{}}"#
        );
    }
}
