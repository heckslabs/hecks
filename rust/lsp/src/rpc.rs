//! LSP's own transport framing over stdio: each message is
//! `Content-Length: <N>\r\n\r\n<N bytes of UTF-8 JSON>`, no other headers
//! read or written (`Content-Type` is optional per the spec and every
//! real client omits it). This is the entire wire protocol below JSON —
//! small enough by hand that pulling in a framing crate for it would
//! cost more in review surface than it saves in typing.

use crate::json::Json;
use std::io::{self, BufRead, Write};

/// Blocks until one full message has arrived on stdin, or returns
/// `Ok(None)` at a clean EOF (the client closed the pipe — `main`'s own
/// loop treats that the same as an `exit` notification).
pub fn read_message(stdin: &mut impl BufRead) -> io::Result<Option<Json>> {
    let mut content_length: Option<usize> = None;
    loop {
        let mut line = String::new();
        let read = stdin.read_line(&mut line)?;
        if read == 0 {
            return Ok(None); // EOF before/between headers
        }
        let line = line.trim_end_matches(['\r', '\n']);
        if line.is_empty() {
            break; // blank line ends the header block
        }
        if let Some(value) = line.strip_prefix("Content-Length:") {
            content_length = Some(value.trim().parse().map_err(|e| {
                io::Error::new(io::ErrorKind::InvalidData, format!("bad Content-Length: {e}"))
            })?);
        }
        // Any other header (Content-Type, ...) is read and ignored.
    }

    let len = content_length.ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidData, "message had no Content-Length header")
    })?;
    let mut buf = vec![0u8; len];
    stdin.read_exact(&mut buf)?;
    let text = String::from_utf8(buf)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("body not UTF-8: {e}")))?;
    let value = Json::parse(&text)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("body not JSON: {e}")))?;
    Ok(Some(value))
}

/// Writes one framed message and flushes — a client blocked reading
/// stdout waits exactly as long as this process takes to flush, so an
/// un-flushed write is a real, observable hang, not just untidy.
pub fn write_message(stdout: &mut impl Write, value: &Json) -> io::Result<()> {
    let body = crate::json::write(value);
    write!(stdout, "Content-Length: {}\r\n\r\n{}", body.len(), body)?;
    stdout.flush()
}

pub fn response(id: Json, result: Json) -> Json {
    Json::object(vec![("jsonrpc", Json::string("2.0")), ("id", id), ("result", result)])
}

pub fn notification(method: &str, params: Json) -> Json {
    Json::object(vec![
        ("jsonrpc", Json::string("2.0")),
        ("method", Json::string(method)),
        ("params", params),
    ])
}

pub fn error_response(id: Json, code: i64, message: &str) -> Json {
    Json::object(vec![
        ("jsonrpc", Json::string("2.0")),
        ("id", id),
        (
            "error",
            Json::object(vec![("code", Json::Number(code)), ("message", Json::string(message))]),
        ),
    ])
}
