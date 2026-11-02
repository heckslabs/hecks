//! Runs the shared parity corpus under `spec/parity/fixtures` through the `hecks-parse` binary and
//! compares each fixture's normalized outcome with its `expected.json`. The Ruby side,
//! `spec/parity/ruby_runner_spec.rb`, iterates the same directory, so a fixture that passes on one
//! side and fails on the other is a divergence between the two parsers.

// reason: these helpers are test scaffolding outside `#[test]` fns, which clippy.toml does not
// cover; a failed unwrap here is the test failing.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

/// A JSON value, read by the minimal parser below (the crate has no dependencies).
#[derive(Debug, Clone, PartialEq)]
enum Json {
    Null,
    Bool(bool),
    Number(String),
    Str(String),
    Array(Vec<Json>),
    Object(Vec<(String, Json)>),
}

const NULL: &Json = &Json::Null;

impl Json {
    fn get(&self, key: &str) -> &Json {
        match self {
            Self::Object(fields) => fields
                .iter()
                .find(|(k, _)| k == key)
                .map_or(NULL, |(_, v)| v),
            _ => NULL,
        }
    }

    fn items(&self) -> &[Self] {
        match self {
            Self::Array(items) => items,
            _ => &[],
        }
    }
}

struct Parser<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl Parser<'_> {
    fn skip_ws(&mut self) {
        while self.peek().is_some_and(|byte| byte.is_ascii_whitespace()) {
            self.pos += 1;
        }
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }

    fn expect(&mut self, byte: u8) -> Result<(), String> {
        self.skip_ws();
        if self.peek() == Some(byte) {
            self.pos += 1;
            Ok(())
        } else {
            Err(format!(
                "expected {:?} at byte {}",
                char::from(byte),
                self.pos
            ))
        }
    }

    fn value(&mut self) -> Result<Json, String> {
        self.skip_ws();
        match self.peek() {
            Some(b'{') => self.object(),
            Some(b'[') => self.array(),
            Some(b'"') => self.string().map(Json::Str),
            Some(b't') => self.literal("true", Json::Bool(true)),
            Some(b'f') => self.literal("false", Json::Bool(false)),
            Some(b'n') => self.literal("null", Json::Null),
            Some(_) => self.number(),
            None => Err("unexpected end of JSON".to_string()),
        }
    }

    fn literal(&mut self, word: &str, value: Json) -> Result<Json, String> {
        if self.bytes[self.pos..].starts_with(word.as_bytes()) {
            self.pos += word.len();
            Ok(value)
        } else {
            Err(format!("bad literal at byte {}", self.pos))
        }
    }

    fn number(&mut self) -> Result<Json, String> {
        let start = self.pos;
        while self
            .peek()
            .is_some_and(|byte| matches!(byte, b'-' | b'+' | b'.' | b'e' | b'E' | b'0'..=b'9'))
        {
            self.pos += 1;
        }
        if self.pos == start {
            return Err(format!("bad value at byte {start}"));
        }
        Ok(Json::Number(
            String::from_utf8_lossy(&self.bytes[start..self.pos]).into_owned(),
        ))
    }

    fn string(&mut self) -> Result<String, String> {
        self.expect(b'"')?;
        let mut out: Vec<u8> = Vec::new();
        loop {
            let byte = self.peek().ok_or("unterminated string")?;
            self.pos += 1;
            match byte {
                b'"' => return String::from_utf8(out).map_err(|error| error.to_string()),
                b'\\' => {
                    let escape = self.peek().ok_or("unterminated escape")?;
                    self.pos += 1;
                    match escape {
                        b'n' => out.push(b'\n'),
                        b't' => out.push(b'\t'),
                        b'r' => out.push(b'\r'),
                        b'b' => out.push(0x08),
                        b'f' => out.push(0x0c),
                        b'u' => {
                            let hex = self
                                .bytes
                                .get(self.pos..self.pos + 4)
                                .ok_or("short \\u escape")?;
                            let code = u32::from_str_radix(
                                std::str::from_utf8(hex).map_err(|e| e.to_string())?,
                                16,
                            )
                            .map_err(|e| e.to_string())?;
                            let ch = char::from_u32(code).ok_or("bad \\u escape")?;
                            let mut buf = [0; 4];
                            out.extend_from_slice(ch.encode_utf8(&mut buf).as_bytes());
                            self.pos += 4;
                        }
                        other => out.push(other),
                    }
                }
                other => out.push(other),
            }
        }
    }

    fn array(&mut self) -> Result<Json, String> {
        self.expect(b'[')?;
        let mut items = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b']') {
            self.pos += 1;
            return Ok(Json::Array(items));
        }
        loop {
            items.push(self.value()?);
            self.skip_ws();
            match self.peek() {
                Some(b',') => self.pos += 1,
                Some(b']') => {
                    self.pos += 1;
                    return Ok(Json::Array(items));
                }
                _ => return Err(format!("expected ',' or ']' at byte {}", self.pos)),
            }
        }
    }

    fn object(&mut self) -> Result<Json, String> {
        self.expect(b'{')?;
        let mut fields = Vec::new();
        self.skip_ws();
        if self.peek() == Some(b'}') {
            self.pos += 1;
            return Ok(Json::Object(fields));
        }
        loop {
            let key = self.string()?;
            self.expect(b':')?;
            fields.push((key, self.value()?));
            self.skip_ws();
            match self.peek() {
                Some(b',') => self.pos += 1,
                Some(b'}') => {
                    self.pos += 1;
                    return Ok(Json::Object(fields));
                }
                _ => return Err(format!("expected ',' or '}}' at byte {}", self.pos)),
            }
        }
    }
}

fn parse_json(text: &str) -> Json {
    let mut parser = Parser {
        bytes: text.as_bytes(),
        pos: 0,
    };
    parser.value().expect("valid JSON")
}

fn corpus_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../spec/parity/fixtures")
}

/// Every directory under `dir` that holds an `expected.json`.
fn fixture_dirs(dir: &Path, found: &mut Vec<PathBuf>) {
    let mut entries: Vec<PathBuf> = fs::read_dir(dir)
        .expect("readable corpus dir")
        .map(|e| e.expect("entry").path())
        .collect();
    entries.sort();
    for path in entries {
        if path.is_dir() {
            if path.join("expected.json").is_file() {
                found.push(path.clone());
            }
            fixture_dirs(&path, found);
        }
    }
}

fn input_files(input: &Path) -> Vec<PathBuf> {
    let mut files: Vec<PathBuf> = fs::read_dir(input)
        .expect("readable input dir")
        .map(|e| e.expect("entry").path())
        .collect();
    files.sort();
    files
}

/// The name in the first `Hecks.bluebook "Name"` header of the input's `.bluebook` file.
fn bluebook_name(files: &[PathBuf]) -> String {
    let bluebook = files
        .iter()
        .find(|path| path.extension().is_some_and(|ext| ext == "bluebook"))
        .expect("a .bluebook input");
    let text = fs::read_to_string(bluebook).expect("readable bluebook");
    let rest = text
        .split("Hecks.bluebook \"")
        .nth(1)
        .expect("a Hecks.bluebook header");
    rest.split('"').next().expect("closed name").to_string()
}

fn run_hecks_parse(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_hecks-parse"))
        .args(args)
        .output()
        .expect("failed to run hecks-parse")
}

/// Maps a refusal's diagnostic to the corpus's code. The Rust diagnostic carries no code, only text.
fn refusal_code(stderr: &str) -> Option<&'static str> {
    if stderr.contains("which no driving adapter answers to") {
        Some("driven_by.outside_set")
    } else {
        None
    }
}

fn refused(code: &str) -> Json {
    Json::Object(vec![
        ("outcome".into(), Json::Str("refused".into())),
        ("code".into(), Json::Str(code.into())),
    ])
}

/// The same shape the Ruby runner writes: each entity with its preconditions' description and canonical text.
fn accepted_outcome(ir: &Json) -> Json {
    let mut entities = Vec::new();
    for aggregate in ir.get("aggregates").items() {
        for entity in aggregate.get("entities").items() {
            let preconditions = entity
                .get("preconditions")
                .items()
                .iter()
                .map(|precondition| {
                    Json::Object(vec![
                        (
                            "description".into(),
                            precondition.get("description").clone(),
                        ),
                        ("canonical".into(), precondition.get("canonical").clone()),
                    ])
                })
                .collect();
            entities.push(Json::Object(vec![
                ("aggregate".into(), aggregate.get("name").clone()),
                ("entity".into(), entity.get("name").clone()),
                ("preconditions".into(), Json::Array(preconditions)),
            ]));
        }
    }
    Json::Object(vec![
        ("outcome".into(), Json::Str("accepted".into())),
        ("entities".into(), Json::Array(entities)),
    ])
}

fn actual_outcome(input: &Path) -> Json {
    let files = input_files(input);
    let name = bluebook_name(&files);
    let hecksagon = files
        .iter()
        .find(|path| path.extension().is_some_and(|ext| ext == "hecksagon"));

    if let Some(hecksagon) = hecksagon {
        let output = run_hecks_parse(&[
            "resolve",
            "--bluebook",
            &name,
            hecksagon.to_str().expect("utf-8 path"),
        ]);
        if output.status.success() {
            return Json::Object(vec![("outcome".into(), Json::Str("accepted".into()))]);
        }
        let stderr = String::from_utf8_lossy(&output.stderr);
        return refused(
            refusal_code(&stderr).unwrap_or_else(|| panic!("unmapped refusal:\n{stderr}")),
        );
    }

    let bluebook = files
        .iter()
        .find(|path| path.extension().is_some_and(|ext| ext == "bluebook"))
        .expect("a .bluebook input");
    let output = run_hecks_parse(&[
        "bluebook",
        "--bluebook",
        &name,
        bluebook.to_str().expect("utf-8 path"),
    ]);
    assert!(
        output.status.success(),
        "hecks-parse refused a fixture it should accept:\n{}",
        String::from_utf8_lossy(&output.stderr)
    );
    accepted_outcome(&parse_json(&String::from_utf8_lossy(&output.stdout)))
}

#[test]
fn corpus_matches_expected_outcomes() {
    let root = corpus_root();
    let mut dirs = Vec::new();
    fixture_dirs(&root, &mut dirs);
    assert!(!dirs.is_empty(), "no fixtures under {}", root.display());

    let mut failures = Vec::new();
    for dir in &dirs {
        let label = dir.strip_prefix(&root).unwrap_or(dir).display().to_string();
        let expected = parse_json(
            &fs::read_to_string(dir.join("expected.json")).expect("readable expected.json"),
        );
        let actual = actual_outcome(&dir.join("input"));
        if actual != expected {
            failures.push(format!(
                "{label}:\n  expected {expected:?}\n  actual   {actual:?}"
            ));
        }
    }
    assert!(
        failures.is_empty(),
        "parity divergences:\n{}",
        failures.join("\n")
    );
}
