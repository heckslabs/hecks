//! A Claude Code child played from a tape, so a session can be proven with no model and no tokens.
//!
//! A tape is JSON lines, one step a line, run in order:
//!
//! - `{"expect": "user", "contains": "..."}` waits for the next user turn on stdin and checks it
//!   holds the text.
//! - `{"emit": {...}, "after_ms": 40}` prints the object as one line after the pause. When it is a
//!   `control_request`, the child waits for the matching `control_response`, as Claude Code does,
//!   and `"answered": "success"` or `"reply_contains": "..."` check the answer.
//! - `{"note": "..."}` is skipped.
//!
//! Control requests the harness sends (`initialize`, `interrupt`) are answered on their own. After
//! the last step the child waits for its stdin to close, then exits 0. A step that is not met in
//! [`WAIT`] fails the replay.

use std::collections::VecDeque;
use std::io::{BufRead, Write};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::thread;
use std::time::{Duration, Instant};

use crate::json::{self, Value};
use crate::protocol;

/// How long one step waits for the harness.
pub const WAIT: Duration = Duration::from_secs(10);

/// One step of a tape.
#[derive(Debug, Clone, PartialEq)]
pub enum Step {
    /// Wait for a user turn holding `contains`.
    ExpectUser { contains: String },
    /// Print `line` after `after_ms`; for a control request, wait for its answer and check it.
    Emit {
        line: Value,
        after_ms: u64,
        answered: Option<String>,
        reply_contains: Option<String>,
    },
}

/// Reads a tape's text into its steps.
///
/// # Errors
///
/// Returns a message naming the line of a step that is not JSON or not a step.
pub fn steps(tape: &str) -> Result<Vec<Step>, String> {
    let mut steps = Vec::new();
    for (index, line) in tape.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        let at = index + 1;
        let step = json::parse(line).map_err(|error| format!("tape line {at}: {error}"))?;
        if step.get("note").is_some() {
            continue;
        }
        if let Some(expected) = step.str_at("expect") {
            if expected != "user" {
                return Err(format!(
                    "tape line {at}: only a user turn is expected, not {expected:?}"
                ));
            }
            steps.push(Step::ExpectUser {
                contains: step.str_at("contains").unwrap_or_default().to_string(),
            });
        } else if let Some(line) = step.get("emit") {
            steps.push(Step::Emit {
                line: line.clone(),
                after_ms: step
                    .get("after_ms")
                    .and_then(Value::as_f64)
                    .map_or(0, |ms| ms as u64),
                answered: step.str_at("answered").map(ToString::to_string),
                reply_contains: step.str_at("reply_contains").map(ToString::to_string),
            });
        } else {
            return Err(format!("tape line {at}: a step names expect, emit or note"));
        }
    }
    Ok(steps)
}

/// Plays `steps` against the harness: reads `input`, writes `out`.
///
/// # Errors
///
/// Returns a message when a step is not met.
pub fn play<R, W>(steps: &[Step], input: R, out: &mut W) -> Result<(), String>
where
    R: BufRead + Send + 'static,
    W: Write,
{
    let (lines, heard) = mpsc::channel();
    thread::spawn(move || {
        for line in input.lines() {
            let Ok(line) = line else { break };
            if lines.send(line).is_err() {
                return;
            }
        }
    });
    let mut child = Child {
        heard,
        held: VecDeque::new(),
        closed: false,
    };
    for (index, step) in steps.iter().enumerate() {
        child
            .step(step, out)
            .map_err(|error| format!("tape step {}: {error}", index + 1))?;
    }
    while !child.closed {
        match child.next(out, None)? {
            Some(line) => child.held.push_back(line),
            None => break,
        }
    }
    Ok(())
}

/// The child's side of the pipes, with the lines read but not yet taken.
struct Child {
    heard: Receiver<String>,
    held: VecDeque<Value>,
    closed: bool,
}

impl Child {
    fn step<W: Write>(&mut self, step: &Step, out: &mut W) -> Result<(), String> {
        match step {
            Step::ExpectUser { contains } => {
                let turn = self.take(out, |line| line.str_at("type") == Some("user"))?;
                let text = turn
                    .get("message")
                    .and_then(|message| message.str_at("content"))
                    .unwrap_or_default();
                if text.contains(contains.as_str()) {
                    Ok(())
                } else {
                    Err(format!("the user turn {text:?} does not hold {contains:?}"))
                }
            }
            Step::Emit {
                line,
                after_ms,
                answered,
                reply_contains,
            } => {
                thread::sleep(Duration::from_millis(*after_ms));
                emit(out, &line.to_json())?;
                if line.str_at("type") != Some("control_request") {
                    return Ok(());
                }
                let id = line.str_at("request_id").unwrap_or_default().to_string();
                let answer = self.take(out, |heard| {
                    heard.str_at("type") == Some("control_response")
                        && heard
                            .get("response")
                            .and_then(|response| response.str_at("request_id"))
                            == Some(id.as_str())
                })?;
                check_answer(&answer, answered.as_deref(), reply_contains.as_deref())
            }
        }
    }

    /// The first line, held or yet to come, that `wanted` accepts.
    fn take<W: Write>(
        &mut self,
        out: &mut W,
        wanted: impl Fn(&Value) -> bool,
    ) -> Result<Value, String> {
        if let Some(at) = self.held.iter().position(&wanted) {
            return self
                .held
                .remove(at)
                .ok_or_else(|| "a held line went missing".to_string());
        }
        let deadline = Instant::now() + WAIT;
        loop {
            let Some(line) = self.next(out, Some(deadline))? else {
                return Err("the harness closed the pipe first".to_string());
            };
            if wanted(&line) {
                return Ok(line);
            }
            self.held.push_back(line);
        }
    }

    /// The next line from the harness, after answering any control request it sends.
    fn next<W: Write>(
        &mut self,
        out: &mut W,
        deadline: Option<Instant>,
    ) -> Result<Option<Value>, String> {
        loop {
            let line = match deadline {
                Some(deadline) => match self
                    .heard
                    .recv_timeout(deadline.saturating_duration_since(Instant::now()))
                {
                    Ok(line) => line,
                    Err(RecvTimeoutError::Timeout) => {
                        return Err(format!("nothing came in {} s", WAIT.as_secs()))
                    }
                    Err(RecvTimeoutError::Disconnected) => return Ok(self.close()),
                },
                None => match self.heard.recv() {
                    Ok(line) => line,
                    Err(_) => return Ok(self.close()),
                },
            };
            if line.trim().is_empty() {
                continue;
            }
            let value = json::parse(&line)
                .map_err(|error| format!("the harness wrote a line not JSON: {error}"))?;
            if value.str_at("type") == Some("control_request") {
                let id = value.str_at("request_id").unwrap_or_default();
                emit(
                    out,
                    &protocol::control_success(id, Value::object::<&str>(vec![])),
                )?;
                continue;
            }
            return Ok(Some(value));
        }
    }

    const fn close(&mut self) -> Option<Value> {
        self.closed = true;
        None
    }
}

fn check_answer(
    answer: &Value,
    answered: Option<&str>,
    reply_contains: Option<&str>,
) -> Result<(), String> {
    let response = answer.get("response").unwrap_or(&Value::Null);
    let subtype = response.str_at("subtype").unwrap_or_default();
    if let Some(wanted) = answered {
        if subtype != wanted {
            return Err(format!("the request was answered {subtype}, not {wanted}"));
        }
    }
    if let Some(wanted) = reply_contains {
        let text = answer.to_json();
        if !text.contains(wanted) {
            return Err(format!("the answer {text} does not hold {wanted:?}"));
        }
    }
    Ok(())
}

fn emit<W: Write>(out: &mut W, line: &str) -> Result<(), String> {
    writeln!(out, "{line}")
        .and_then(|()| out.flush())
        .map_err(|error| format!("cannot write: {error}"))
}

/// Turns a recording `serve --record` wrote for one session into a tape.
///
/// What the child printed becomes `emit` steps, paced by the gaps between them; each user turn
/// the harness wrote becomes an `expect` of its first line. Control messages the harness wrote are
/// left out: the replay answers and awaits them on its own.
///
/// # Errors
///
/// Returns a message naming a recording line that is not an entry.
pub fn tape_from_recording(recording: &str) -> Result<String, String> {
    let mut tape = String::new();
    let mut last_ms = 0.0;
    for (index, entry) in recording.lines().enumerate() {
        if entry.trim().is_empty() {
            continue;
        }
        let entry =
            json::parse(entry).map_err(|error| format!("recording line {}: {error}", index + 1))?;
        let at_ms = entry
            .get("at_ms")
            .and_then(Value::as_f64)
            .unwrap_or(last_ms);
        let line = json::parse(entry.str_at("line").unwrap_or_default())
            .map_err(|error| format!("recording line {}: {error}", index + 1))?;
        let step = match entry.str_at("dir") {
            Some("from") => {
                let gap = (at_ms - last_ms).max(0.0).round();
                Value::object(vec![("emit", line), ("after_ms", Value::Number(gap))])
            }
            Some("to") if line.str_at("type") == Some("user") => {
                let text = line
                    .get("message")
                    .and_then(|message| message.str_at("content"))
                    .unwrap_or_default();
                let first = text.lines().next().unwrap_or_default();
                Value::object(vec![
                    ("expect", Value::text("user")),
                    ("contains", Value::text(first)),
                ])
            }
            _ => continue,
        };
        last_ms = at_ms;
        tape.push_str(&step.to_json());
        tape.push('\n');
    }
    Ok(tape)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    fn played(tape: &str, input: &str) -> Result<String, String> {
        let mut out = Vec::new();
        play(&steps(tape)?, Cursor::new(input.to_string()), &mut out)?;
        Ok(String::from_utf8(out).unwrap())
    }

    #[test]
    fn reads_each_kind_of_step() {
        let read = steps("{\"note\":\"hi\"}\n{\"expect\":\"user\",\"contains\":\"go\"}\n{\"emit\":{\"type\":\"result\"},\"after_ms\":5}\n").unwrap();
        assert_eq!(read.len(), 2);
        assert_eq!(
            read[0],
            Step::ExpectUser {
                contains: "go".into()
            }
        );
    }

    #[test]
    fn refuses_a_step_it_cannot_read() {
        assert!(steps("{\"wait\":1}").unwrap_err().contains("tape line 1"));
    }

    #[test]
    fn answers_initialize_and_plays_a_turn() {
        let input = format!(
            "{}\n{}\n",
            protocol::control_request("h1", "initialize"),
            protocol::user_message("go now")
        );
        let out = played("{\"expect\":\"user\",\"contains\":\"go\"}\n{\"emit\":{\"type\":\"result\",\"result\":\"ok\"}}\n", &input).unwrap();
        let lines: Vec<&str> = out.lines().collect();
        assert!(lines[0].contains("\"request_id\":\"h1\""));
        assert!(lines[1].contains("\"result\":\"ok\""));
    }

    #[test]
    fn fails_a_user_turn_that_does_not_hold_the_text() {
        let input = format!("{}\n", protocol::user_message("something else"));
        assert!(
            played("{\"expect\":\"user\",\"contains\":\"go\"}\n", &input)
                .unwrap_err()
                .contains("does not hold")
        );
    }

    #[test]
    fn waits_for_the_answer_to_its_own_request() {
        let answer =
            protocol::control_success("c1", Value::object(vec![("behavior", Value::text("deny"))]));
        let tape = "{\"emit\":{\"type\":\"control_request\",\"request_id\":\"c1\",\"request\":{\"subtype\":\"can_use_tool\"}},\"answered\":\"success\",\"reply_contains\":\"deny\"}\n";
        assert!(played(tape, &format!("{answer}\n")).is_ok());
    }

    #[test]
    fn turns_a_recording_into_a_tape() {
        let user = protocol::user_message("Message a-1 from a:\nhello");
        let recording = [
            Value::object(vec![
                ("dir", Value::text("to")),
                ("at_ms", Value::Number(1.0)),
                ("line", Value::text(user)),
            ]),
            Value::object(vec![
                ("dir", Value::text("from")),
                ("at_ms", Value::Number(41.0)),
                (
                    "line",
                    Value::text("{\"type\":\"result\",\"result\":\"ok\"}"),
                ),
            ]),
        ]
        .iter()
        .map(Value::to_json)
        .collect::<Vec<_>>()
        .join("\n");
        let tape = tape_from_recording(&recording).unwrap();
        let read = steps(&tape).unwrap();
        assert_eq!(
            read[0],
            Step::ExpectUser {
                contains: "Message a-1 from a:".into()
            }
        );
        assert!(matches!(read[1], Step::Emit { after_ms: 40, .. }));
    }
}
