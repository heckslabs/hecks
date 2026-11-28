//! A crew run's journal, and a replay of the run held to it.
//!
//! The journal is the directory `serve --record DIR` writes: one recording a session, every line
//! to and from its child. Read back, a recording is the session's acts in order:
//!
//! - `given`: a user turn the harness wrote it (its brief, a message, a notice), whole;
//! - `interrupted`: the harness cut its running turn short;
//! - `permission`: a tool it asked to use, and whether the harness allowed or denied it;
//! - `sent`: a message it sent with `send_message`, to whom, what it said, what about, and whether
//!   it was urgent;
//! - `turn_ended`: a turn it ended, whether in error, and its last text.
//!
//! Timings are not acts: a replay is held to what each session was given and did, in order, not
//! to when. [`compare`] holds a replay's journal to the run's: an act that matches is explained,
//! and the first one in a session that does not is that session's surprise.

use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

use crate::json::{self, Value};
use crate::mcp;
use crate::protocol::{self, Heard, Request, MCP_SERVER};

/// Each session's acts, by name.
pub type Acts = BTreeMap<String, Vec<Value>>;

/// A session's acts, read from its recording.
///
/// # Errors
///
/// Returns a message naming the recording line that is not a recorded line.
pub fn acts(recording: &str) -> Result<Vec<Value>, String> {
    let mut acts = Vec::new();
    let mut asked: BTreeMap<String, String> = BTreeMap::new();
    for (index, entry) in recording.lines().enumerate() {
        if entry.trim().is_empty() {
            continue;
        }
        let at = index + 1;
        let entry = json::parse(entry).map_err(|error| format!("recording line {at}: {error}"))?;
        let text = entry
            .str_at("line")
            .ok_or_else(|| format!("recording line {at} holds no line"))?;
        let line = json::parse(text).map_err(|error| format!("recording line {at}: {error}"))?;
        match entry.str_at("dir") {
            Some("to") => acts.extend(written(&line, &mut asked)),
            Some("from") => acts.extend(printed(text, &mut asked)),
            _ => {
                return Err(format!(
                    "recording line {at} is neither to nor from its child"
                ))
            }
        }
    }
    Ok(acts)
}

/// The act a line the harness wrote a child stands for, if any.
fn written(line: &Value, asked: &mut BTreeMap<String, String>) -> Option<Value> {
    match line.str_at("type") {
        Some("user") => {
            let text = line
                .get("message")
                .and_then(|message| message.str_at("content"))
                .unwrap_or_default();
            Some(act("given", vec![("text", Value::text(text))]))
        }
        Some("control_request") => {
            let subtype = line
                .get("request")
                .and_then(|request| request.str_at("subtype"));
            (subtype == Some("interrupt")).then(|| act("interrupted", vec![]))
        }
        Some("control_response") => {
            let response = line.get("response")?;
            let tool = asked.remove(response.str_at("request_id")?)?;
            let behavior = response
                .get("response")
                .and_then(|answer| answer.str_at("behavior"))
                .unwrap_or_default();
            Some(act(
                "permission",
                vec![
                    ("tool", Value::text(tool)),
                    ("behavior", Value::text(behavior)),
                ],
            ))
        }
        _ => None,
    }
}

/// The act a line a child printed stands for, if any. A permission it asks for is kept until the
/// harness answers it, and is an act then.
fn printed(line: &str, asked: &mut BTreeMap<String, String>) -> Option<Value> {
    match protocol::decode(line).ok()? {
        Heard::Asked {
            request_id,
            request: Request::Permission { tool, .. },
        } => {
            asked.insert(request_id, tool);
            None
        }
        Heard::Asked {
            request: Request::Mcp { server, message },
            ..
        } if server == MCP_SERVER => mcp::handle(&message).outgoing.map(|outgoing| {
            let mut fields = vec![
                ("to", Value::text(outgoing.to)),
                ("text", Value::text(outgoing.text)),
            ];
            if let Some(about) = outgoing.about {
                fields.push(("about", Value::text(about)));
            }
            if outgoing.urgent {
                fields.push(("urgent", Value::Bool(true)));
            }
            act("sent", fields)
        }),
        Heard::TurnEnded { is_error, text } => Some(act(
            "turn_ended",
            vec![
                ("is_error", Value::Bool(is_error)),
                ("text", Value::text(text)),
            ],
        )),
        _ => None,
    }
}

fn act(kind: &str, fields: Vec<(&str, Value)>) -> Value {
    let mut pairs = vec![("act", Value::text(kind))];
    pairs.extend(fields);
    Value::object(pairs)
}

/// Every session's acts in a journal directory: each `<session>.jsonl` in it, read as a recording.
///
/// # Errors
///
/// Returns a message when the directory or a recording in it cannot be read.
pub fn read(dir: &Path) -> Result<Acts, String> {
    let entries =
        fs::read_dir(dir).map_err(|error| format!("cannot read {}: {error}", dir.display()))?;
    let mut sessions = Acts::new();
    for entry in entries {
        let path = entry
            .map_err(|error| format!("cannot read {}: {error}", dir.display()))?
            .path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("jsonl") {
            continue;
        }
        let Some(session) = path.file_stem().and_then(|stem| stem.to_str()) else {
            continue;
        };
        let recording = fs::read_to_string(&path)
            .map_err(|error| format!("cannot read {}: {error}", path.display()))?;
        let read = acts(&recording).map_err(|error| format!("{}: {error}", path.display()))?;
        sessions.insert(session.to_string(), read);
    }
    Ok(sessions)
}

/// How many turns a session ended, among its acts.
pub fn turns(acts: &[Value]) -> usize {
    acts.iter()
        .filter(|act| act.str_at("act") == Some("turn_ended"))
        .count()
}

/// Each session's turns and acts, as JSON: what a replay of the run waits for.
pub fn outline(sessions: &Acts) -> Value {
    Value::Object(
        sessions
            .iter()
            .map(|(session, acts)| {
                let counts = Value::object(vec![
                    ("turns", Value::Number(turns(acts) as f64)),
                    ("acts", Value::Number(acts.len() as f64)),
                ]);
                (session.clone(), counts)
            })
            .collect(),
    )
}

/// The first act of a session where a replay and the journal part: its place, and the act each
/// holds there (`None` where one has run out of acts, or never had the session).
#[derive(Debug, Clone, PartialEq)]
pub struct Surprise {
    pub session: String,
    pub at: usize,
    pub journal: Option<Value>,
    pub replay: Option<Value>,
}

/// A replay held to its journal.
#[derive(Debug, Clone, PartialEq)]
pub struct Compared {
    /// The sessions either holds.
    pub sessions: usize,
    /// The acts that matched, up to each session's surprise.
    pub matched: usize,
    /// Each session's first surprise, by session name.
    pub surprises: Vec<Surprise>,
}

impl Compared {
    /// Whether the replay did all the journal says, and nothing else.
    pub const fn held(&self) -> bool {
        self.surprises.is_empty()
    }

    /// The comparison as JSON.
    pub fn to_value(&self) -> Value {
        let surprises = self
            .surprises
            .iter()
            .map(|surprise| {
                Value::object(vec![
                    ("session", Value::text(&surprise.session)),
                    ("at", Value::Number(surprise.at as f64)),
                    ("journal", surprise.journal.clone().unwrap_or(Value::Null)),
                    ("replay", surprise.replay.clone().unwrap_or(Value::Null)),
                ])
            })
            .collect();
        Value::object(vec![
            ("held", Value::Bool(self.held())),
            ("sessions", Value::Number(self.sessions as f64)),
            ("matched", Value::Number(self.matched as f64)),
            ("surprises", Value::Array(surprises)),
        ])
    }
}

/// Holds a replay's acts to the journal's, session by session, in order.
pub fn compare(journal: &Acts, replay: &Acts) -> Compared {
    let mut names: Vec<&String> = journal.keys().chain(replay.keys()).collect();
    names.sort();
    names.dedup();
    let none: Vec<Value> = Vec::new();
    let mut matched = 0;
    let mut surprises = Vec::new();
    for name in &names {
        let wanted = journal.get(*name).unwrap_or(&none);
        let done = replay.get(*name).unwrap_or(&none);
        let alike = wanted.iter().zip(done).take_while(|(a, b)| a == b).count();
        matched += alike;
        if alike < wanted.len().max(done.len())
            || journal.contains_key(*name) != replay.contains_key(*name)
        {
            surprises.push(Surprise {
                session: (*name).clone(),
                at: alike,
                journal: wanted.get(alike).cloned(),
                replay: done.get(alike).cloned(),
            });
        }
    }
    Compared {
        sessions: names.len(),
        matched,
        surprises,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(dir: &str, line: &str) -> String {
        Value::object(vec![
            ("dir", Value::text(dir)),
            ("at_ms", Value::Number(1.0)),
            ("line", Value::text(line)),
        ])
        .to_json()
            + "\n"
    }

    fn send(to: &str, text: &str, urgent: bool) -> String {
        let mut arguments = vec![("to", Value::text(to)), ("text", Value::text(text))];
        if urgent {
            arguments.push(("urgent", Value::Bool(true)));
        }
        let message = Value::object(vec![
            ("jsonrpc", Value::text("2.0")),
            ("id", Value::Number(3.0)),
            ("method", Value::text("tools/call")),
            (
                "params",
                Value::object(vec![
                    ("name", Value::text("send_message")),
                    ("arguments", Value::object(arguments)),
                ]),
            ),
        ]);
        Value::object(vec![
            ("type", Value::text("control_request")),
            ("request_id", Value::text("m1")),
            (
                "request",
                Value::object(vec![
                    ("subtype", Value::text("mcp_message")),
                    ("server_name", Value::text(MCP_SERVER)),
                    ("message", message),
                ]),
            ),
        ])
        .to_json()
    }

    fn recording() -> String {
        [
            entry("to", &protocol::control_request("harness-1", "initialize")),
            entry("to", &protocol::user_message("You are the coder.\nWork the item.")),
            entry("from", r#"{"type":"system","subtype":"init","session_id":"s"}"#),
            entry(
                "from",
                r#"{"type":"control_request","request_id":"p1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{}}}"#,
            ),
            entry(
                "to",
                &protocol::control_success("p1", protocol::permission_denied("withheld")),
            ),
            entry("from", &send("reviewer", "Ready for review.", true)),
            entry("to", &protocol::control_request("harness-2", "interrupt")),
            entry("from", r#"{"type":"result","subtype":"success","is_error":false,"result":"Done."}"#),
        ]
        .concat()
    }

    fn kinds(acts: &[Value]) -> Vec<&str> {
        acts.iter().filter_map(|act| act.str_at("act")).collect()
    }

    #[test]
    fn reads_a_sessions_acts_in_order() {
        let acts = acts(&recording()).unwrap();
        assert_eq!(
            kinds(&acts),
            ["given", "permission", "sent", "interrupted", "turn_ended"]
        );
        assert_eq!(
            acts[0].str_at("text"),
            Some("You are the coder.\nWork the item.")
        );
        assert_eq!(acts[1].str_at("tool"), Some("Bash"));
        assert_eq!(acts[1].str_at("behavior"), Some("deny"));
        assert_eq!(acts[2].str_at("to"), Some("reviewer"));
        assert_eq!(acts[2].get("urgent"), Some(&Value::Bool(true)));
        assert_eq!(acts[4].str_at("text"), Some("Done."));
        assert_eq!(turns(&acts), 1);
    }

    #[test]
    fn refuses_a_recording_line_that_is_not_one() {
        let error = acts("{\"dir\":\"to\"}\n").unwrap_err();
        assert!(error.contains("line 1 holds no line"), "{error}");
        let error = acts(&entry("sideways", "{}")).unwrap_err();
        assert!(error.contains("neither to nor from"), "{error}");
    }

    fn sessions(pairs: &[(&str, &str)]) -> Acts {
        pairs
            .iter()
            .map(|(name, recording)| ((*name).to_string(), acts(recording).unwrap()))
            .collect()
    }

    #[test]
    fn holds_a_replay_that_did_what_the_journal_says() {
        let journal = sessions(&[("coder", &recording())]);
        let compared = compare(&journal, &journal.clone());
        assert!(compared.held());
        assert_eq!(compared.matched, 5);
        assert_eq!(compared.sessions, 1);
    }

    #[test]
    fn names_the_first_act_a_replay_does_otherwise() {
        let journal = sessions(&[("coder", &recording())]);
        let other = recording().replace("Ready for review.", "Not ready.");
        let compared = compare(&journal, &sessions(&[("coder", &other)]));
        assert!(!compared.held());
        assert_eq!(compared.matched, 2);
        let surprise = &compared.surprises[0];
        assert_eq!((surprise.session.as_str(), surprise.at), ("coder", 2));
        assert_eq!(
            surprise.journal.as_ref().and_then(|act| act.str_at("text")),
            Some("Ready for review.")
        );
        assert_eq!(
            surprise.replay.as_ref().and_then(|act| act.str_at("text")),
            Some("Not ready.")
        );
    }

    #[test]
    fn names_a_replay_that_stops_short_or_goes_on() {
        let journal = sessions(&[("coder", &recording())]);
        let short: String = recording()
            .lines()
            .take(3)
            .fold(String::new(), |mut kept, line| {
                kept.push_str(line);
                kept.push('\n');
                kept
            });
        let compared = compare(&journal, &sessions(&[("coder", &short)]));
        assert_eq!(compared.surprises[0].at, 1);
        assert!(compared.surprises[0].replay.is_none());
        let compared = compare(&sessions(&[("coder", &short)]), &journal);
        assert!(compared.surprises[0].journal.is_none());
    }

    #[test]
    fn names_a_session_only_one_of_them_holds() {
        let journal = sessions(&[("coder", &recording()), ("reviewer", "")]);
        let compared = compare(&journal, &sessions(&[("coder", &recording())]));
        assert_eq!(compared.sessions, 2);
        assert_eq!(compared.surprises.len(), 1);
        assert_eq!(compared.surprises[0].session, "reviewer");
    }

    #[test]
    fn outlines_each_sessions_turns_and_acts() {
        let outline = outline(&sessions(&[("coder", &recording())]));
        assert_eq!(outline.to_json(), r#"{"coder":{"turns":1,"acts":5}}"#);
    }
}
