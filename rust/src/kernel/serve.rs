//! The host protocol over a line-framed stream (ADR 0189): `rust --serve`.
//!
//! One JSON message per line in, one per line out. Beyond the steps a session answers
//! (`cli::Session::handle`) the connection takes `hello`, `open` and `close`, and while a dispatch
//! runs the kernel may write a `callback` frame and read the host's `answer` before it goes on.
//! The kernel does no I/O of its own (ADR 0012); this loop is the one place that touches the
//! stream, and the kernel proper only calls the `needs::Asker` it is given.

use super::cli::{refusal_answer, Session};
use super::{needs, Json};
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::io::{BufRead, Write};
use std::rc::Rc;

/// The protocol versions this kernel speaks.
const SUPPORTED: &[i64] = &[1];

/// The features a `hello` answer lists, so a client can tell what it may ask for.
const FEATURES: &[&str] = &["sessions", "callbacks"];

/// The two ends of the stream, shared by the message loop and the callback in flight.
struct Wire<R, W> {
    input: RefCell<R>,
    output: RefCell<W>,
    asked: Cell<i64>,
}

impl<R: BufRead, W: Write> Wire<R, W> {
    /// The next line, or `None` when the host closed its end.
    fn read(&self) -> Option<String> {
        let mut line = String::new();
        match self.input.borrow_mut().read_line(&mut line) {
            Ok(0) | Err(_) => None,
            Ok(_) => Some(line),
        }
    }

    /// Writes one frame and flushes it; `false` when the host is gone.
    fn write(&self, frame: &Json) -> bool {
        let mut output = self.output.borrow_mut();
        writeln!(output, "{}", frame.to_json_string()).is_ok() && output.flush().is_ok()
    }
}

/// What a connection keeps: its sessions, and whether the host offered to be asked for facts.
struct Connection {
    default: Session,
    named: HashMap<String, Session>,
    callbacks: bool,
}

pub fn serve<R: BufRead + 'static, W: Write + 'static>(input: R, output: W) {
    let wire = Rc::new(Wire {
        input: RefCell::new(input),
        output: RefCell::new(output),
        asked: Cell::new(0),
    });
    let mut connection = Connection {
        default: Session::new(),
        named: HashMap::new(),
        callbacks: false,
    };
    while let Some(line) = wire.read() {
        if line.trim().is_empty() {
            continue;
        }
        let answer = match Json::parse(&line) {
            Err(e) => refusal_answer(&format!("invalid JSON: {e}")),
            Ok(message) => route(&wire, &mut connection, &message),
        };
        if !wire.write(&answer) {
            break;
        }
    }
}

fn route<R: BufRead + 'static, W: Write + 'static>(
    wire: &Rc<Wire<R, W>>,
    connection: &mut Connection,
    message: &Json,
) -> Json {
    if let Some(hello) = message.get("hello") {
        return negotiate(hello, connection);
    }
    if let Some(name) = message.get("open") {
        return open(connection, name);
    }
    if let Some(name) = message.get("close") {
        return close(connection, name);
    }
    let session = match message.get("session") {
        None => &mut connection.default,
        Some(name) => {
            let Some(found) = name.as_str().and_then(|n| connection.named.get_mut(n)) else {
                return refusal_answer(&format!("no such session {}", name.to_json_string()));
            };
            found
        }
    };
    if connection.callbacks {
        let verb = message
            .get("verb")
            .or_else(|| message.get("dry_run"))
            .and_then(Json::as_str)
            .unwrap_or_default();
        needs::set_asker(Some(asker(wire, verb.to_string())));
    }
    let answer = session.handle(message);
    needs::set_asker(None);
    answer
}

/// `{"hello": {"protocols": [1], "callbacks": true, "needs": {...}}}`: picks the highest version
/// both ends speak, installs the tables of needed facts and defaults, and records whether the
/// host will answer callbacks. A client that names no version is taken to speak version 1.
fn negotiate(hello: &Json, connection: &mut Connection) -> Json {
    let named = hello.get("protocols").and_then(Json::as_array);
    let mut theirs: Vec<i64> = named.map_or_else(
        || {
            hello
                .get("protocol")
                .and_then(Json::as_i64)
                .into_iter()
                .collect()
        },
        |list| list.iter().filter_map(Json::as_i64).collect(),
    );
    if theirs.is_empty() {
        theirs.push(1);
    }
    let Some(agreed) = SUPPORTED.iter().filter(|v| theirs.contains(v)).max() else {
        return refusal_answer(&format!(
            "no common protocol: the client speaks {theirs:?}, this kernel speaks {SUPPORTED:?}"
        ));
    };
    needs::install(hello.get("needs"));
    needs::install_queries(hello.get("query_needs"));
    needs::install_defaults(hello.get("defaults"));
    connection.callbacks = matches!(hello.get("callbacks"), Some(Json::Bool(true)));
    Json::obj(vec![
        ("ok", Json::Bool(true)),
        ("protocol", Json::int(*agreed)),
        (
            "features",
            Json::Array(FEATURES.iter().map(|f| Json::str(*f)).collect()),
        ),
    ])
}

/// `{"open": "name"}`: a new session with its own store and sagas.
fn open(connection: &mut Connection, name: &Json) -> Json {
    let Some(name) = name.as_str().filter(|n| !n.is_empty()) else {
        return refusal_answer("a session needs a name");
    };
    if connection.named.contains_key(name) {
        return refusal_answer(&format!("session {name:?} is already open"));
    }
    connection.named.insert(name.to_string(), Session::new());
    Json::obj(vec![("ok", Json::Bool(true)), ("session", Json::str(name))])
}

/// `{"close": "name"}`: drops a session and what it held. The default session cannot be closed.
fn close(connection: &mut Connection, name: &Json) -> Json {
    let closed = name.as_str().and_then(|n| connection.named.remove(n));
    match closed {
        Some(_) => Json::obj(vec![("ok", Json::Bool(true))]),
        None => refusal_answer(&format!("no such session {}", name.to_json_string())),
    }
}

/// The callback a dispatch runs under: it writes `{"callback": {id, ask, fact, type, verb}}` and
/// reads the host's `{"id": id, "answer": value}`. A null or missing answer, an answer for another
/// id, or a closed stream leaves the fact unanswered, as with no callback at all.
fn asker<R: BufRead + 'static, W: Write + 'static>(
    wire: &Rc<Wire<R, W>>,
    verb: String,
) -> needs::Asker {
    let wire = Rc::clone(wire);
    Box::new(move |fact, attribute_type| {
        let id = wire.asked.get() + 1;
        wire.asked.set(id);
        let frame = Json::obj(vec![(
            "callback",
            Json::obj(vec![
                ("id", Json::int(id)),
                ("ask", Json::str("fact")),
                ("fact", Json::str(fact)),
                ("type", Json::str(attribute_type)),
                ("verb", Json::str(verb.clone())),
            ]),
        )]);
        if !wire.write(&frame) {
            return None;
        }
        let reply = Json::parse(&wire.read()?).ok()?;
        if reply.get("id").and_then(Json::as_i64) != Some(id) {
            return None;
        }
        match reply.get("answer") {
            Some(Json::Null) | None => None,
            Some(value) => Some(value.clone()),
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A writer the test can read back after the connection ends.
    #[derive(Clone, Default)]
    struct Sink(Rc<RefCell<Vec<u8>>>);

    impl Write for Sink {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            self.0.borrow_mut().extend_from_slice(bytes);
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    fn talk(lines: &[&str]) -> Vec<Json> {
        let sink = Sink::default();
        let input = std::io::Cursor::new(format!("{}\n", lines.join("\n")));
        serve(input, sink.clone());
        let text = String::from_utf8(sink.0.borrow().clone()).unwrap();
        text.lines().map(|l| Json::parse(l).unwrap()).collect()
    }

    fn ok(answer: &Json) -> bool {
        matches!(answer.get("ok"), Some(Json::Bool(true)))
    }

    fn error(answer: &Json) -> &str {
        answer.get("error").and_then(Json::as_str).unwrap_or("")
    }

    #[test]
    fn a_hello_agrees_the_highest_common_version_and_lists_its_features() {
        let answers = talk(&[r#"{"hello": {"protocols": [3, 1]}}"#]);
        assert!(ok(&answers[0]));
        assert_eq!(answers[0].get("protocol").and_then(Json::as_i64), Some(1));
        assert_eq!(
            answers[0]
                .get("features")
                .and_then(Json::as_array)
                .map(<[Json]>::len),
            Some(2)
        );
    }

    #[test]
    fn a_hello_with_no_common_version_is_refused_naming_both_sides() {
        let answers = talk(&[r#"{"hello": {"protocols": [2]}}"#]);
        assert!(!ok(&answers[0]));
        assert!(error(&answers[0]).contains("no common protocol"));
    }

    #[test]
    fn a_session_opens_closes_and_refuses_what_is_not_open() {
        let answers = talk(&[
            r#"{"open": "a"}"#,
            r#"{"open": "a"}"#,
            r#"{"snapshot": true, "session": "a"}"#,
            r#"{"restore": true, "session": "a"}"#,
            r#"{"close": "a"}"#,
            r#"{"restore": true, "session": "a"}"#,
            r#"{"close": "a"}"#,
        ]);
        assert!(ok(&answers[0]));
        assert!(error(&answers[1]).contains("already open"));
        assert!(ok(&answers[2]) && ok(&answers[3]));
        assert!(ok(&answers[4]));
        assert!(error(&answers[5]).contains("no such session"));
        assert!(error(&answers[6]).contains("no such session"));
    }

    #[test]
    fn sessions_do_not_share_state() {
        let answers = talk(&[
            r#"{"open": "a"}"#,
            r#"{"open": "b"}"#,
            r#"{"snapshot": true, "session": "a"}"#,
            r#"{"restore": true, "session": "b"}"#,
            r#"{"restore": true}"#,
        ]);
        assert!(error(&answers[3]).contains("no snapshot"));
        assert!(error(&answers[4]).contains("no snapshot"));
    }

    #[test]
    fn a_step_with_no_session_runs_in_the_default_one_as_before() {
        let answers = talk(&[r#"{"snapshot": true}"#, r#"{"restore": true}"#, "not json"]);
        assert!(ok(&answers[0]) && ok(&answers[1]));
        assert!(error(&answers[2]).contains("invalid JSON"));
    }
}
