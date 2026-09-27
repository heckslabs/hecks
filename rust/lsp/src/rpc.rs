//! LSP stdio framing: `Content-Length: <N>\r\n\r\n` followed by N bytes of UTF-8 JSON.
//! No other headers are written, and any others read are ignored.

use crate::json::Json;
use std::io::{self, BufRead, Write};

/// Blocks until one full message has arrived, or returns `Ok(None)` at EOF.
pub fn read_message(stdin: &mut impl BufRead) -> io::Result<Option<Json>> {
    let mut content_length: Option<usize> = None;
    loop {
        let mut line = String::new();
        let read = stdin.read_line(&mut line)?;
        if read == 0 {
            return Ok(None);
        }
        let line = line.trim_end_matches(['\r', '\n']);
        if line.is_empty() {
            break;
        }
        if let Some(value) = line.strip_prefix("Content-Length:") {
            content_length = Some(value.trim().parse().map_err(|e| {
                io::Error::new(io::ErrorKind::InvalidData, format!("bad Content-Length: {e}"))
            })?);
        }
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

/// Writes one framed message and flushes; an unflushed write hangs a client waiting to read.
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
