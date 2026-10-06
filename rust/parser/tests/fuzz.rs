//! Seeded fuzzing of `hecks-parse`, std-only (ADR 0012: the crate takes no dependencies).
//!
//! Every input is a mutation of a fixture or a generated bluebook. The properties are that the
//! binary never panics, never hangs, answers only with exit 0, 1 or 2, explains every refusal on
//! stderr, and prints identical output for identical input. `HECKS_PARSE_FUZZ_ITERATIONS` and
//! `HECKS_PARSE_FUZZ_SEED` widen or move the run; a failure prints the seed and keeps its input.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

const DEFAULT_ITERATIONS: u64 = 400;
const DEFAULT_SEED: u64 = 0x5eed_c0de;
const HANG_LIMIT: Duration = Duration::from_secs(10);

/// xorshift64*: deterministic, so a printed seed reproduces a failure exactly.
struct Rng(u64);

impl Rng {
    fn new(seed: u64) -> Self {
        Rng(seed.max(1))
    }

    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_f491_4f6c_dd1d)
    }

    fn below(&mut self, bound: usize) -> usize {
        (self.next() % bound.max(1) as u64) as usize
    }

    fn pick<'a, T>(&mut self, items: &'a [T]) -> &'a T {
        &items[self.below(items.len())]
    }
}

fn env_u64(name: &str, default: u64) -> u64 {
    std::env::var(name)
        .ok()
        .and_then(|raw| raw.parse().ok())
        .unwrap_or(default)
}

fn fixtures_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures")
}

fn fixtures_with(extension: &str) -> Vec<(String, Vec<u8>)> {
    let mut found: Vec<(String, Vec<u8>)> = fs::read_dir(fixtures_dir())
        .expect("fixtures directory")
        .filter_map(|entry| entry.ok().map(|e| e.path()))
        .filter(|path| path.extension().is_some_and(|ext| ext == extension))
        .map(|path| {
            let name = path.file_name().unwrap().to_string_lossy().into_owned();
            (name, fs::read(&path).expect("fixture bytes"))
        })
        .collect();
    found.sort();
    found
}

/// The name in a `Hecks.bluebook "Name"` or `Hecks.hecksagon "Name"` header, else `Fuzzed`.
fn header_name(source: &[u8]) -> String {
    let text = String::from_utf8_lossy(source);
    text.lines()
        .find(|line| line.starts_with("Hecks."))
        .and_then(|line| line.split('"').nth(1))
        .unwrap_or("Fuzzed")
        .to_string()
}

const WORDS: &[&str] = &[
    "aggregate",
    "command",
    "attribute",
    "sets",
    "given",
    "invariant",
    "policy",
    "on",
    "trigger",
    "lifecycle",
    "transition",
    "query",
    "where",
    "limit",
    "order_by",
    "read_model",
    "group_by",
    "entity",
    "value_object",
    "one_of",
    "member",
    "emits",
    "needs",
    "role",
    "goal",
    "do",
    "end",
    "String",
    "Integer",
    "list_of",
    "reference_to",
    "identified_by",
    "process_manager",
    "starts_on",
    "ends_on",
    "dispatch",
    "attaches",
    "from:",
    "vendor",
    "port",
    "operation",
];

const ODD_TEXT: &[&str] = &[
    "\0",
    "\u{feff}",
    "\u{202e}",
    "é",
    "\u{1F4A5}",
    "\r\n",
    "\t",
    "\\",
    "\"",
    "'",
    "#{",
    "99999999999999999999999999999999999999",
    "-0.0e999999",
    "0x7fffffffffffffff",
    "1_000_000_000_000_000_000_000",
    ":",
    "::",
    "->",
    "|",
    "{",
    "}",
    "[",
    "(",
];

fn char_boundary_after(bytes: &[u8], mut at: usize) -> usize {
    while at < bytes.len() && (bytes[at] & 0b1100_0000) == 0b1000_0000 {
        at += 1;
    }
    at
}

/// One structure-aware or byte-level change; every operator tolerates any input, empty included.
fn mutate_once(rng: &mut Rng, input: &mut Vec<u8>) {
    let len = input.len();
    match rng.below(14) {
        0 if len > 0 => {
            let at = rng.below(len);
            input[at] ^= 1 << rng.below(8);
        }
        1 if len > 0 => {
            let at = rng.below(len);
            input[at] = rng.next() as u8;
        }
        2 if len > 0 => input.truncate(rng.below(len)),
        3 if len > 0 => {
            let from = rng.below(len);
            let span = rng.below(len - from + 1).min(256);
            let chunk = input[from..from + span].to_vec();
            let at = rng.below(len);
            input.splice(at..at, chunk);
        }
        4 if len > 0 => {
            let from = rng.below(len);
            let span = rng.below(len - from + 1);
            input.drain(from..from + span);
        }
        5 => {
            let at = char_boundary_after(input, rng.below(len + 1));
            input.splice(at..at, rng.pick(ODD_TEXT).bytes());
        }
        6 => {
            let at = rng.below(len + 1);
            input.splice(at..at, rng.pick(WORDS).bytes());
        }
        7 => {
            // Duplicate a whole line, which is how a repeated declaration arises.
            let text = String::from_utf8_lossy(input).into_owned();
            let lines: Vec<&str> = text.lines().collect();
            if !lines.is_empty() {
                let mut doubled = lines.clone();
                let which = rng.below(lines.len());
                doubled.insert(which, lines[which]);
                *input = doubled.join("\n").into_bytes();
            }
        }
        8 => {
            // Delete a whole line, which unbalances a `do`/`end` pair.
            let text = String::from_utf8_lossy(input).into_owned();
            let mut lines: Vec<&str> = text.lines().collect();
            if !lines.is_empty() {
                lines.remove(rng.below(lines.len()));
                *input = lines.join("\n").into_bytes();
            }
        }
        9 => {
            // Swap two lines.
            let text = String::from_utf8_lossy(input).into_owned();
            let mut lines: Vec<&str> = text.lines().collect();
            if lines.len() > 1 {
                let (a, b) = (rng.below(lines.len()), rng.below(lines.len()));
                lines.swap(a, b);
                *input = lines.join("\n").into_bytes();
            }
        }
        10 => {
            // Deep nesting: a run of opened blocks or brackets with no closers.
            let depth = 1 + rng.below(400);
            let opener = rng.pick(&["do\n", "(", "[", "{", "not ", "-"]);
            let at = char_boundary_after(input, rng.below(len + 1));
            input.splice(at..at, opener.repeat(depth).bytes());
        }
        11 => {
            // Splice a word from the grammar over a random run of identifier characters.
            let text = String::from_utf8_lossy(input).into_owned();
            let tokens: Vec<&str> = text.split(' ').collect();
            if !tokens.is_empty() {
                let mut swapped: Vec<String> = tokens.iter().map(|t| t.to_string()).collect();
                let which = rng.below(swapped.len());
                swapped[which] = rng.pick(WORDS).to_string();
                *input = swapped.join(" ").into_bytes();
            }
        }
        12 => {
            // Invalid UTF-8.
            let at = rng.below(len + 1);
            input.splice(at..at, [0xff, 0xfe, 0xc0, 0x80]);
        }
        _ => {
            // Very long line.
            let at = char_boundary_after(input, rng.below(len + 1));
            let filler = vec![b'a'; 1 + rng.below(100_000)];
            input.splice(at..at, filler);
        }
    }
}

fn mutate(rng: &mut Rng, seed: &[u8]) -> Vec<u8> {
    let mut input = seed.to_vec();
    for _ in 0..1 + rng.below(4) {
        mutate_once(rng, &mut input);
    }
    input
}

const TYPES: &[&str] = &[
    "String",
    "Integer",
    "Float",
    "Boolean",
    "Date",
    "list_of(String)",
];

/// A syntactically plausible bluebook built from the grammar words, so mutation starts from
/// shapes the fixtures do not carry.
fn generate_bluebook(rng: &mut Rng, chapter: &str) -> Vec<u8> {
    let mut out = format!("Hecks.bluebook \"{chapter}\" do\n");
    for a in 0..1 + rng.below(3) {
        out += &format!("  aggregate \"Agg{a}\" do\n");
        let attrs = 1 + rng.below(4);
        for n in 0..attrs {
            out += &format!("    attribute :f{n}, {}\n", rng.pick(TYPES));
        }
        for c in 0..rng.below(3) {
            out += &format!("    command \"Do{c}\" do\n      attribute :f0, String\n");
            if rng.below(2) == 0 {
                out += "      sets :f0\n";
            }
            if rng.below(3) == 0 {
                out += &format!(
                    "      given(\"f0 is set\") {{ f0 != {} }}\n",
                    rng.below(100)
                );
            }
            out += "    end\n";
        }
        if rng.below(2) == 0 {
            out += "    lifecycle :f0, default: \"a\" do\n      transition \"Do0\" => \"b\"\n    end\n";
        }
        out += "  end\n";
    }
    out += "end\n";
    out.into_bytes()
}

struct Outcome {
    output: Output,
    elapsed: Duration,
}

/// Runs `hecks-parse` with a wall-clock limit; a run past the limit is killed and reported.
fn run_parser(args: &[&std::ffi::OsStr]) -> Result<Outcome, String> {
    let started = Instant::now();
    let mut child = Command::new(env!("CARGO_BIN_EXE_hecks-parse"))
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("spawn failed: {e}"))?;
    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();
    let drain = |mut pipe: Box<dyn std::io::Read + Send>| {
        std::thread::spawn(move || {
            let mut buf = Vec::new();
            let _ = pipe.read_to_end(&mut buf);
            buf
        })
    };
    let out_thread = drain(Box::new(stdout));
    let err_thread = drain(Box::new(stderr));
    loop {
        match child.try_wait().map_err(|e| e.to_string())? {
            Some(status) => {
                return Ok(Outcome {
                    output: Output {
                        status,
                        stdout: out_thread.join().unwrap_or_default(),
                        stderr: err_thread.join().unwrap_or_default(),
                    },
                    elapsed: started.elapsed(),
                })
            }
            None if started.elapsed() > HANG_LIMIT => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("hung past {HANG_LIMIT:?}"));
            }
            None => std::thread::sleep(Duration::from_millis(1)),
        }
    }
}

struct Scratch(PathBuf);

impl Scratch {
    fn new(label: &str) -> Self {
        let dir =
            std::env::temp_dir().join(format!("hecks_parse_fuzz_{label}_{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("scratch dir");
        Scratch(dir)
    }

    fn write(&self, name: &str, bytes: &[u8]) -> PathBuf {
        let path = self.0.join(name);
        fs::write(&path, bytes).expect("write input");
        path
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// Keeps a failing input where the person running the test can find it.
fn keep_failure(label: &str, seed: u64, iteration: u64, bytes: &[u8]) -> PathBuf {
    let path = std::env::temp_dir().join(format!(
        "hecks_parse_fuzz_failure_{label}_{seed}_{iteration}"
    ));
    let _ = fs::write(&path, bytes);
    path
}

/// The properties every run must satisfy; returns the problem, or `None` when the run is sound.
fn check(outcome: &Outcome) -> Option<String> {
    let code = outcome.output.status.code();
    let stderr = String::from_utf8_lossy(&outcome.output.stderr);
    match code {
        None => Some("killed by a signal".to_string()),
        Some(101) => Some(format!("panicked: {stderr}")),
        Some(0) if outcome.output.stdout.is_empty() => Some("exit 0 with empty stdout".to_string()),
        Some(0) => None,
        Some(1) | Some(2) if stderr.trim().is_empty() => {
            Some("refused without a diagnostic on stderr".to_string())
        }
        Some(1) | Some(2) if stderr.contains("panicked") => Some(format!("panicked: {stderr}")),
        Some(1) | Some(2) => None,
        Some(other) => Some(format!("unexpected exit {other}: {stderr}")),
    }
}

/// Returns `(accepted, refused)` so a caller can tell a fuzzer that reaches the parser's body
/// from one whose every input dies at the first line.
fn fuzz_inputs(label: &str, extension: &str, subcommand: &str, generate: bool) -> (u64, u64) {
    let iterations = env_u64("HECKS_PARSE_FUZZ_ITERATIONS", DEFAULT_ITERATIONS);
    let seed = env_u64("HECKS_PARSE_FUZZ_SEED", DEFAULT_SEED);
    let corpus = fixtures_with(extension);
    assert!(!corpus.is_empty(), "no .{extension} fixtures to fuzz");
    let mut rng = Rng::new(seed);
    let scratch = Scratch::new(label);
    let mut problems: Vec<String> = Vec::new();
    let (mut accepted, mut refused) = (0u64, 0u64);

    for iteration in 0..iterations {
        let (name, base) = rng.pick(&corpus).clone();
        let chapter = header_name(&base);
        let seed_bytes = if generate && rng.below(3) == 0 {
            generate_bluebook(&mut rng, &chapter)
        } else {
            base
        };
        let input = mutate(&mut rng, &seed_bytes);
        let path = scratch.write(&format!("input.{extension}"), &input);
        let args: Vec<&std::ffi::OsStr> = [subcommand, "--chapter", &chapter]
            .iter()
            .map(|s| std::ffi::OsStr::new(*s))
            .chain(std::iter::once(path.as_os_str()))
            .collect();
        match run_parser(&args) {
            Err(why) => {
                let kept = keep_failure(label, seed, iteration, &input);
                problems.push(format!(
                    "[{name} seed={seed} iter={iteration}] {why} (input kept at {})",
                    kept.display()
                ));
            }
            Ok(outcome) => {
                if let Some(why) = check(&outcome) {
                    let kept = keep_failure(label, seed, iteration, &input);
                    problems.push(format!(
                        "[{name} seed={seed} iter={iteration}] {why} (input kept at {})",
                        kept.display()
                    ));
                } else if outcome.output.status.code() != Some(0) {
                    refused += 1;
                } else {
                    accepted += 1;
                    let again = run_parser(&args).expect("second run");
                    if again.output.stdout != outcome.output.stdout {
                        problems.push(format!(
                            "[{name} seed={seed} iter={iteration}] nondeterministic output"
                        ));
                    }
                }
            }
        }
        if problems.len() >= 5 {
            break;
        }
    }
    assert!(problems.is_empty(), "{label}: {}", problems.join("\n"));
    (accepted, refused)
}

#[test]
fn mutated_bluebooks_never_panic_or_hang() {
    let (accepted, refused) = fuzz_inputs("bluebook", "bluebook", "chapter", true);
    assert!(
        accepted > 0,
        "no mutated bluebook parsed, so the fuzzer never got past the header"
    );
    assert!(
        refused > 0,
        "no mutated bluebook was refused, so the mutators are not reaching the parser"
    );
}

#[test]
fn mutated_hecksagons_never_panic_or_hang() {
    let (accepted, refused) = fuzz_inputs("hecksagon_resolve", "hecksagon", "resolve", false);
    assert!(accepted + refused > 0);
}

#[test]
fn every_fixture_parses_the_same_twice() {
    for (name, bytes) in fixtures_with("bluebook") {
        let scratch = Scratch::new("determinism");
        let path = scratch.write(&name, &bytes);
        let chapter = header_name(&bytes);
        let args = [
            std::ffi::OsStr::new("chapter"),
            std::ffi::OsStr::new("--chapter"),
            std::ffi::OsStr::new(&chapter),
            path.as_os_str(),
        ];
        let first = run_parser(&args).expect("first run");
        let second = run_parser(&args).expect("second run");
        assert_eq!(
            first.output.stdout, second.output.stdout,
            "{name}: output differs between runs"
        );
        assert_eq!(
            first.output.status.code(),
            second.output.status.code(),
            "{name}: exit differs"
        );
        assert!(first.elapsed < HANG_LIMIT);
    }
}

/// Runs `hecks-parse chapter --chapter Fuzzed` on `source` and answers the outcome.
fn parse_source(label: &str, source: &str) -> Outcome {
    let scratch = Scratch::new(label);
    let path = scratch.write("input.bluebook", source.as_bytes());
    run_parser(&[
        std::ffi::OsStr::new("chapter"),
        std::ffi::OsStr::new("--chapter"),
        std::ffi::OsStr::new("Fuzzed"),
        path.as_os_str(),
    ])
    .expect("run")
}

#[test]
fn a_role_or_goal_that_is_not_a_literal_is_refused_not_invented() {
    for word in ["role", "goal"] {
        let source = format!(
            "Hecks.bluebook \"Fuzzed\" do\n  aggregate \"Widget\" do\n    attribute :name, String\n    command \"Rename\" do\n      {word} sets :name\n    end\n  end\nend\n"
        );
        let outcome = parse_source("literal", &source);
        assert_eq!(outcome.output.status.code(), Some(1), "{word}");
        assert!(String::from_utf8_lossy(&outcome.output.stderr).contains("is not a literal"));
    }
}

#[test]
fn double_quoted_escapes_decode_like_ruby() {
    let source = "Hecks.bluebook \"Fuzzed\" do\n  aggregate \"Wid\\tget\\u00e9\" do\n    attribute :name, String\n  end\nend\n";
    let stdout =
        String::from_utf8_lossy(&parse_source("escapes", source).output.stdout).into_owned();
    assert!(stdout.contains("\"Wid\\tget"), "tab escape lost: {stdout}");
}

#[test]
fn unreadable_and_missing_inputs_are_usage_errors() {
    let scratch = Scratch::new("usage");
    let missing: &Path = &scratch.0.join("absent.bluebook");
    let outcome = run_parser(&[
        std::ffi::OsStr::new("chapter"),
        std::ffi::OsStr::new("--chapter"),
        std::ffi::OsStr::new("X"),
        missing.as_os_str(),
    ])
    .expect("run");
    assert_eq!(outcome.output.status.code(), Some(2));
    assert!(check(&outcome).is_none());
}
