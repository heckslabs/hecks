//! The supervisor: one process that holds every session's child and its pipes.
//!
//! It reads ops on its stdin, one JSON object a line, and writes tells on its stdout, one JSON
//! object a line, each stamped `at_ms` from the supervisor's own start. It decides nothing about
//! the mail: a session's `send_message` becomes a `sent` tell, and the message reaches its
//! addressee only when the caller (the Harness bluebook's policy, through its adapter) sends a
//! `deliver` op. What the supervisor does decide is when a delivery is written: a session in the
//! middle of a turn holds it, and it is written the moment that turn ends, so `delivered` marks
//! the moment the addressee starts on it.
//!
//! A delivery marked `urgent` is not left to wait for the turn: it goes ahead of the held
//! deliveries, the session's turn is interrupted (an `interrupt` control request, told as
//! `interrupted`), and once the cut turn ends the urgent message is written as the next one.
//!
//! A delivery the supervisor refuses is not lost on its sender: a sender that still runs is told,
//! as a turn of its own from `harness`, that its message did not arrive and why, and the
//! `noticed` tell records it. A sender relaying for someone else learns at once that the one it
//! asked was not reached.
//!
//! The supervisor also keeps the run's clock: every tick it writes a `tick` tell, so a wait the
//! bluebook times (a question nobody settled, say) is checked against the supervisor's own clock
//! even when no session says anything.
//!
//! A session reopened in a standing seat is told its brief and then the `handover` its seat's last
//! session left ([`brief::opening`]), so the new child takes up where the last one stopped.
//!
//! A session opened for a role holds the tools its role names (the `open` op's `tools`), beside
//! `send_message`: the supervisor allows a use of one of them, and refuses every other tool
//! ([`role::permits`]). Each answer is told, `allowed` or `denied`, so the ledger records it.
//!
//! Ops: `open` (session, program, args, model, cwd, brief, handover, tools), `deliver` (session,
//! message, from, text, about, urgent), `stop` (session) and `quit`. Tells: `ready`, `opened`,
//! `started`, `sent`, `allowed`, `denied`, `turn_ended`, `queued`, `interrupted`, `delivered`,
//! `noticed`, `stopped`, `refused`, `fault`, `tick` and `quit`.

use std::collections::{BTreeMap, VecDeque};
use std::fs::{self, File};
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;
use std::time::{Duration, Instant};

use crate::brief;
use crate::json::{self, Value};
use crate::mcp;
use crate::protocol::{self, Heard, Request, MCP_SERVER};
use crate::role;

/// How long a stopped child has to exit on its own before it is killed.
pub const STOP_GRACE: Duration = Duration::from_secs(5);

/// The variable a Claude Code child must not see, so it bills the signed-in subscription and
/// never an API key the shell happens to hold.
pub const WITHHELD_ENV: &str = "ANTHROPIC_API_KEY";

/// How often the supervisor writes a `tick` tell, unless `serve` is given another interval.
pub const TICK: Duration = Duration::from_secs(60);

/// What the supervisor's one loop hears, from any of its threads.
#[derive(Debug)]
enum Event {
    /// One op line from the caller.
    Op(String),
    /// The caller closed the supervisor's stdin.
    OpsClosed,
    /// One line a session's child printed.
    Line(String, String),
    /// A session's child closed its stdout.
    Closed(String),
    /// A stopped session's grace ran out.
    Deadline(String),
    /// The clock's interval passed.
    Tick,
}

/// The name a notice from the supervisor itself is written from.
pub const HARNESS: &str = "harness";

/// A message held for a session that is mid-turn, or a notice the supervisor writes it.
#[derive(Debug, Clone)]
struct Delivery {
    message: String,
    from: String,
    text: String,
    about: Option<String>,
    notice: bool,
    urgent: bool,
}

/// One session: its child, its stdin, whether a turn is running and whether it is being cut short.
struct Session {
    child: Child,
    tools: Vec<String>,
    stdin: Option<ChildStdin>,
    busy: bool,
    interrupting: bool,
    held: VecDeque<Delivery>,
}

/// The supervisor's state, owned by its one loop.
pub struct Supervisor<W: Write> {
    out: W,
    started: Instant,
    events: Sender<Event>,
    sessions: BTreeMap<String, Session>,
    record: Option<PathBuf>,
    sent: BTreeMap<String, u64>,
    requests: u64,
    quitting: bool,
}

/// Runs the supervisor until the caller quits or closes its stdin, and every child has exited.
///
/// `ops` is read on a thread of its own; tells go to `out`. With `record`, every line to and from
/// each child is appended to `<record>/<session>.jsonl`, the raw recording `hecks-harness tape`
/// turns into a replay tape. A `tick` tell is written every `tick`.
///
/// # Errors
///
/// Returns a message when a tell cannot be written.
pub fn serve<R, W>(ops: R, out: W, record: Option<PathBuf>, tick: Duration) -> Result<(), String>
where
    R: BufRead + Send + 'static,
    W: Write,
{
    let (events, heard) = mpsc::channel();
    let reader = events.clone();
    thread::spawn(move || {
        for line in ops.lines() {
            let Ok(line) = line else { break };
            if !line.trim().is_empty() && reader.send(Event::Op(line)).is_err() {
                return;
            }
        }
        let _ = reader.send(Event::OpsClosed);
    });
    let clock = events.clone();
    thread::spawn(move || loop {
        thread::sleep(tick);
        if clock.send(Event::Tick).is_err() {
            return;
        }
    });
    if let Some(dir) = &record {
        fs::create_dir_all(dir)
            .map_err(|error| format!("cannot make {}: {error}", dir.display()))?;
    }
    let mut supervisor = Supervisor {
        out,
        started: Instant::now(),
        events,
        sessions: BTreeMap::new(),
        record,
        sent: BTreeMap::new(),
        requests: 0,
        quitting: false,
    };
    supervisor.run(&heard)
}

impl<W: Write> Supervisor<W> {
    fn run(&mut self, heard: &Receiver<Event>) -> Result<(), String> {
        self.tell("ready", vec![])?;
        while let Ok(event) = heard.recv() {
            match event {
                Event::Op(line) => self.op(&line)?,
                Event::OpsClosed => self.quit()?,
                Event::Line(session, line) => self.line(&session, &line)?,
                Event::Closed(session) => self.closed(&session)?,
                Event::Deadline(session) => self.deadline(&session),
                Event::Tick => self.tell("tick", vec![])?,
            }
            if self.quitting && self.sessions.is_empty() {
                return self.tell("quit", vec![]);
            }
        }
        Ok(())
    }

    fn op(&mut self, line: &str) -> Result<(), String> {
        let op = match json::parse(line) {
            Ok(op) => op,
            Err(error) => {
                return self.tell(
                    "refused",
                    vec![("reason", Value::text(format!("not JSON: {error}")))],
                )
            }
        };
        let session = op.str_at("session").unwrap_or_default().to_string();
        match op.str_at("op").unwrap_or_default() {
            "open" => self.open(&session, &op),
            "deliver" => self.deliver(&session, &op),
            "stop" => self.stop(&session),
            "quit" => self.quit(),
            other => self.refuse(&session, &format!("no op {other:?}")),
        }
    }

    fn open(&mut self, session: &str, op: &Value) -> Result<(), String> {
        if session.is_empty() || session == HARNESS || self.sessions.contains_key(session) {
            return self.refuse(
                session,
                "a session needs a name no open session has, and not the harness's own",
            );
        }
        let Some(program) = op.str_at("program").filter(|name| !name.is_empty()) else {
            return self.refuse(session, "open names no program");
        };
        let args: Vec<String> = op.get("args").and_then(Value::as_array).map_or_else(
            || protocol::claude_args(op.str_at("model")),
            |args| {
                args.iter()
                    .filter_map(Value::as_str)
                    .map(ToString::to_string)
                    .collect()
            },
        );
        let mut command = Command::new(program);
        command
            .args(&args)
            .env_remove(WITHHELD_ENV)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped());
        if let Some(cwd) = op.str_at("cwd").filter(|dir| !dir.is_empty()) {
            command.current_dir(cwd);
        }
        let mut child = match command.spawn() {
            Ok(child) => child,
            Err(error) => return self.refuse(session, &format!("cannot start {program}: {error}")),
        };
        let stdin = child.stdin.take();
        if let Some(stdout) = child.stdout.take() {
            let events = self.events.clone();
            let name = session.to_string();
            thread::spawn(move || {
                for line in BufReader::new(stdout).lines() {
                    let Ok(line) = line else { break };
                    if !line.trim().is_empty()
                        && events.send(Event::Line(name.clone(), line)).is_err()
                    {
                        return;
                    }
                }
                let _ = events.send(Event::Closed(name));
            });
        }
        let pid = f64::from(child.id());
        let tools: Vec<String> = op
            .get("tools")
            .and_then(Value::as_array)
            .unwrap_or_default()
            .iter()
            .filter_map(Value::as_str)
            .map(ToString::to_string)
            .collect();
        self.sessions.insert(
            session.to_string(),
            Session {
                child,
                tools,
                stdin,
                busy: false,
                interrupting: false,
                held: VecDeque::new(),
            },
        );
        self.tell(
            "opened",
            vec![
                ("session", Value::text(session)),
                ("pid", Value::Number(pid)),
            ],
        )?;
        self.requests += 1;
        let initialize =
            protocol::control_request(&format!("harness-{}", self.requests), "initialize");
        self.write(session, &initialize)?;
        if let Some(brief) = op.str_at("brief").filter(|text| !text.is_empty()) {
            let first = brief::opening(brief, op.str_at("handover"));
            self.write(session, &protocol::user_message(&first))?;
            if let Some(open) = self.sessions.get_mut(session) {
                open.busy = true;
            }
        }
        Ok(())
    }

    fn deliver(&mut self, session: &str, op: &Value) -> Result<(), String> {
        let delivery = Delivery {
            message: op.str_at("message").unwrap_or_default().to_string(),
            from: op.str_at("from").unwrap_or_default().to_string(),
            text: op.str_at("text").unwrap_or_default().to_string(),
            about: op
                .str_at("about")
                .filter(|about| !about.is_empty())
                .map(ToString::to_string),
            notice: false,
            urgent: op.get("urgent").and_then(Value::as_bool).unwrap_or(false),
        };
        if delivery.message.is_empty() || delivery.text.is_empty() {
            return self.refuse(session, "a delivery needs a message id and text");
        }
        let refusal = match self.sessions.get(session) {
            None => Some("no open session has that name"),
            Some(target) if target.stdin.is_none() => Some("the session is stopping"),
            Some(_) => None,
        };
        if let Some(reason) = refusal {
            self.refused_delivery(session, &delivery.message, reason)?;
            return self.notify(session, &delivery, reason);
        }
        self.write_or_hold(session, delivery)
    }

    /// Tells a still-running sender that its message to `session` was not delivered, as a turn
    /// of its own from `harness`, about the message it sent.
    fn notify(&mut self, session: &str, refused: &Delivery, reason: &str) -> Result<(), String> {
        let sender_runs = self
            .sessions
            .get(&refused.from)
            .is_some_and(|sender| sender.stdin.is_some());
        if !sender_runs {
            return Ok(());
        }
        let notice = Delivery {
            message: refused.message.clone(),
            from: HARNESS.to_string(),
            text: format!(
                "Your message {} to {session} was not delivered: {reason}.",
                refused.message
            ),
            about: Some(refused.message.clone()),
            notice: true,
            urgent: false,
        };
        self.write_or_hold(&refused.from, notice)
    }

    /// Writes a delivery now, or holds it while the session is mid-turn. An urgent one is held
    /// ahead of every delivery that is not, and cuts the running turn short.
    fn write_or_hold(&mut self, session: &str, delivery: Delivery) -> Result<(), String> {
        let Some(target) = self.sessions.get_mut(session) else {
            return Ok(());
        };
        if !target.busy {
            return self.hand(session, &delivery);
        }
        let message = delivery.message.clone();
        let notice = delivery.notice;
        let urgent = delivery.urgent;
        if urgent {
            let ahead = target.held.iter().take_while(|held| held.urgent).count();
            target.held.insert(ahead, delivery);
        } else {
            target.held.push_back(delivery);
        }
        let held = target.held.len() as f64;
        let interrupt = urgent && !target.interrupting;
        if interrupt {
            target.interrupting = true;
        }
        let mut fields = vec![
            ("session", Value::text(session)),
            ("message", Value::text(&message)),
            ("held", Value::Number(held)),
            ("notice", Value::Bool(notice)),
        ];
        if urgent {
            fields.push(("urgent", Value::Bool(true)));
        }
        self.tell("queued", fields)?;
        if interrupt {
            self.interrupt(session, &message)?;
        }
        Ok(())
    }

    /// Asks a session's child to cut its running turn short, for an urgent `message`.
    fn interrupt(&mut self, session: &str, message: &str) -> Result<(), String> {
        self.requests += 1;
        let request = protocol::control_request(&format!("harness-{}", self.requests), "interrupt");
        self.write(session, &request)?;
        self.tell(
            "interrupted",
            vec![
                ("session", Value::text(session)),
                ("message", Value::text(message)),
            ],
        )
    }

    /// Writes one delivery as the session's next user turn.
    fn hand(&mut self, session: &str, delivery: &Delivery) -> Result<(), String> {
        let text = if delivery.notice {
            format!("Notice from {HARNESS}:\n{}", delivery.text)
        } else {
            let about = delivery
                .about
                .as_ref()
                .map_or_else(String::new, |about| format!(", about {about}"));
            format!(
                "Message {} from {}{about}:\n{}",
                delivery.message, delivery.from, delivery.text
            )
        };
        self.write(session, &protocol::user_message(&text))?;
        if let Some(target) = self.sessions.get_mut(session) {
            target.busy = true;
        }
        let mut fields = vec![
            ("session", Value::text(session)),
            ("message", Value::text(&delivery.message)),
        ];
        if delivery.notice {
            return self.tell("noticed", fields);
        }
        fields.push(("from", Value::text(&delivery.from)));
        if let Some(about) = &delivery.about {
            fields.push(("about", Value::text(about)));
        }
        if delivery.urgent {
            fields.push(("urgent", Value::Bool(true)));
        }
        self.tell("delivered", fields)
    }

    fn stop(&mut self, session: &str) -> Result<(), String> {
        let Some(target) = self.sessions.get_mut(session) else {
            return self.refuse(session, "no open session has that name");
        };
        if target.stdin.take().is_some() {
            let events = self.events.clone();
            let name = session.to_string();
            thread::spawn(move || {
                thread::sleep(STOP_GRACE);
                let _ = events.send(Event::Deadline(name));
            });
        }
        Ok(())
    }

    fn quit(&mut self) -> Result<(), String> {
        self.quitting = true;
        let names: Vec<String> = self.sessions.keys().cloned().collect();
        for name in names {
            self.stop(&name)?;
        }
        Ok(())
    }

    fn deadline(&mut self, session: &str) {
        if let Some(target) = self.sessions.get_mut(session) {
            let _ = target.child.kill();
        }
    }

    fn closed(&mut self, session: &str) -> Result<(), String> {
        let Some(mut gone) = self.sessions.remove(session) else {
            return Ok(());
        };
        drop(gone.stdin.take());
        let code = gone.child.wait().ok().and_then(|status| status.code());
        let undelivered: Vec<Value> = gone
            .held
            .iter()
            .filter(|held| !held.notice)
            .map(|held| Value::text(&held.message))
            .collect();
        self.tell(
            "stopped",
            vec![
                ("session", Value::text(session)),
                (
                    "code",
                    code.map_or(Value::Null, |code| Value::Number(f64::from(code))),
                ),
                ("undelivered", Value::Array(undelivered)),
            ],
        )
    }

    fn line(&mut self, session: &str, line: &str) -> Result<(), String> {
        self.recorded(session, "from", line);
        let heard = match protocol::decode(line) {
            Ok(heard) => heard,
            Err(error) => {
                return self.tell(
                    "fault",
                    vec![
                        ("session", Value::text(session)),
                        ("error", Value::text(error)),
                    ],
                );
            }
        };
        match heard {
            Heard::Started { claude_session } => self.tell(
                "started",
                vec![
                    ("session", Value::text(session)),
                    ("claude_session", Value::text(claude_session)),
                ],
            ),
            Heard::Asked {
                request_id,
                request,
            } => self.asked(session, &request_id, request),
            Heard::TurnEnded { is_error, text } => self.turn_ended(session, is_error, &text),
            Heard::Answered { .. } | Heard::Said { .. } => Ok(()),
        }
    }

    fn asked(&mut self, session: &str, request_id: &str, request: Request) -> Result<(), String> {
        match request {
            Request::Permission { tool, input } => {
                let held = self
                    .sessions
                    .get(session)
                    .is_some_and(|open| role::permits(&open.tools, &tool, &input));
                let (answer, kind) = if held {
                    (protocol::permission_allowed(input), "allowed")
                } else {
                    let reason = format!(
                        "{tool} is withheld in this session: it holds send_message and the tools its role names."
                    );
                    (protocol::permission_denied(&reason), "denied")
                };
                self.write(session, &protocol::control_success(request_id, answer))?;
                self.tell(
                    kind,
                    vec![
                        ("session", Value::text(session)),
                        ("tool", Value::text(tool)),
                    ],
                )
            }
            Request::Mcp { server, message } if server == MCP_SERVER => {
                let handled = mcp::handle(&message);
                let answer = control_success(request_id, handled.reply);
                self.write(session, &answer)?;
                match handled.outgoing {
                    Some(outgoing) => {
                        let count = self.sent.entry(session.to_string()).or_default();
                        *count += 1;
                        let id = format!("{session}-{count}");
                        let mut fields = vec![
                            ("session", Value::text(session)),
                            ("message", Value::text(id)),
                            ("to", Value::text(outgoing.to)),
                            ("text", Value::text(outgoing.text)),
                        ];
                        if let Some(about) = outgoing.about {
                            fields.push(("about", Value::text(about)));
                        }
                        if outgoing.urgent {
                            fields.push(("urgent", Value::Bool(true)));
                        }
                        self.tell("sent", fields)
                    }
                    None => Ok(()),
                }
            }
            Request::Mcp { server, .. } => self.write(
                session,
                &protocol::control_error(request_id, &format!("no MCP server {server}")),
            ),
            Request::Unknown { subtype } => self.write(
                session,
                &protocol::control_error(request_id, &format!("no answer for {subtype}")),
            ),
        }
    }

    fn turn_ended(&mut self, session: &str, is_error: bool, text: &str) -> Result<(), String> {
        self.tell(
            "turn_ended",
            vec![
                ("session", Value::text(session)),
                ("is_error", Value::Bool(is_error)),
                ("text", Value::text(text)),
            ],
        )?;
        let next = match self.sessions.get_mut(session) {
            Some(target) => {
                target.busy = false;
                target.interrupting = false;
                if target.stdin.is_some() {
                    target.held.pop_front()
                } else {
                    None
                }
            }
            None => None,
        };
        next.map_or(Ok(()), |delivery| self.hand(session, &delivery))
    }

    fn refuse(&mut self, session: &str, reason: &str) -> Result<(), String> {
        self.tell(
            "refused",
            vec![
                ("session", Value::text(session)),
                ("reason", Value::text(reason)),
            ],
        )
    }

    fn refused_delivery(
        &mut self,
        session: &str,
        message: &str,
        reason: &str,
    ) -> Result<(), String> {
        self.tell(
            "refused",
            vec![
                ("session", Value::text(session)),
                ("message", Value::text(message)),
                ("reason", Value::text(reason)),
            ],
        )
    }

    /// Writes one line to a session's child; a broken pipe is a `fault` tell, not an error.
    fn write(&mut self, session: &str, line: &str) -> Result<(), String> {
        self.recorded(session, "to", line);
        let written = self
            .sessions
            .get_mut(session)
            .and_then(|target| target.stdin.as_mut())
            .map(|stdin| writeln!(stdin, "{line}").and_then(|()| stdin.flush()));
        match written {
            Some(Err(error)) => self.tell(
                "fault",
                vec![
                    ("session", Value::text(session)),
                    ("error", Value::text(format!("cannot write: {error}"))),
                ],
            ),
            _ => Ok(()),
        }
    }

    fn recorded(&self, session: &str, direction: &str, line: &str) {
        let Some(dir) = &self.record else { return };
        let entry = Value::object(vec![
            ("dir", Value::text(direction)),
            ("at_ms", Value::Number(self.elapsed_ms())),
            ("line", Value::text(line)),
        ]);
        let path = dir.join(format!("{session}.jsonl"));
        if let Ok(mut file) = File::options().create(true).append(true).open(path) {
            let _ = writeln!(file, "{}", entry.to_json());
        }
    }

    fn elapsed_ms(&self) -> f64 {
        self.started.elapsed().as_millis() as f64
    }

    fn tell(&mut self, kind: &str, fields: Vec<(&str, Value)>) -> Result<(), String> {
        let mut pairs = vec![
            ("tell", Value::text(kind)),
            ("at_ms", Value::Number(self.elapsed_ms())),
        ];
        pairs.extend(fields);
        writeln!(self.out, "{}", Value::object(pairs).to_json())
            .and_then(|()| self.out.flush())
            .map_err(|error| format!("cannot write a tell: {error}"))
    }
}

/// The MCP reply as the child reads it: wrapped in `mcp_response`.
fn control_success(request_id: &str, reply: Value) -> String {
    protocol::control_success(request_id, Value::object(vec![("mcp_response", reply)]))
}
