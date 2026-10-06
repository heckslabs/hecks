//! Shared pieces of the boundary fuzz tests that sit beside `api`, `server`, `web`, `auth`,
//! `expr_json` and `ir`: a seeded generator, a guard that fails on a panic or a hang, and
//! generators for hostile text and JSON. Std-only, so a failing case is named by its seed alone.
//!
//! Run more seeds with `HOST_FUZZ_SEEDS=2000 cargo test fuzz`.

use serde_json::{json, Map, Value};
use std::sync::mpsc;
use std::time::Duration;

/// xorshift64*: no dependency, and the seed is the whole reproduction.
pub(crate) struct Rng(u64);

impl Rng {
    pub(crate) fn new(seed: u64) -> Self {
        Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1)
    }

    pub(crate) fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    pub(crate) fn below(&mut self, n: usize) -> usize {
        (self.next() % n.max(1) as u64) as usize
    }

    pub(crate) fn chance(&mut self, one_in: usize) -> bool {
        self.below(one_in) == 0
    }

    pub(crate) fn pick<'a, T>(&mut self, items: &'a [T]) -> &'a T {
        &items[self.below(items.len())]
    }
}

/// How many seeds each fuzz test runs.
pub(crate) fn seeds() -> u64 {
    std::env::var("HOST_FUZZ_SEEDS").ok().and_then(|v| v.parse().ok()).unwrap_or(200)
}

/// The most a single guarded case may take before it counts as a hang.
pub(crate) const LIMIT: Duration = Duration::from_secs(20);

/// Runs `f` on a thread with a 2 MiB stack (a tokio worker's default) and returns its answer.
/// A panic or a missed `LIMIT` fails the test and names `label`; a stack overflow aborts the
/// whole binary, which fails it too.
pub(crate) fn guarded<T: Send + 'static>(label: &str, f: impl FnOnce() -> T + Send + 'static) -> T {
    let (tx, rx) = mpsc::channel();
    let handle = std::thread::Builder::new()
        .stack_size(2 * 1024 * 1024)
        .spawn(move || {
            let _ = tx.send(f());
        })
        .expect("spawn a guarded thread");
    match rx.recv_timeout(LIMIT) {
        Ok(value) => {
            handle.join().expect("guarded thread joined");
            value
        }
        Err(mpsc::RecvTimeoutError::Timeout) => panic!("{label}: no answer within {LIMIT:?} (hang)"),
        Err(mpsc::RecvTimeoutError::Disconnected) => {
            let panic = handle.join().expect_err("a guarded thread that sent nothing must have panicked");
            let message = panic.downcast_ref::<String>().cloned().or_else(|| panic.downcast_ref::<&str>().map(|s| s.to_string()));
            panic!("{label}: panicked: {}", message.unwrap_or_default())
        }
    }
}

/// Pieces that break naive text handling: multi-byte characters next to ASCII delimiters (the
/// shape that slices through a char boundary), control characters, NUL, bidi marks, astral
/// planes, combining marks, percent signs, and every JSON/URL/cookie delimiter.
const PIECES: &[&str] = &[
    "a", "Z", "0", "9", " ", "\"", "'", "\\", "/", "%", "%4", "%41", "%zz", "%+1", "+", "=", "&", ";", "?", "#", ".", "..", "-", "_", ":", ",", "{", "}", "[", "]",
    "\n", "\t", "\r", "\u{0}", "\u{1f}", "\u{7f}", "é", "ü", "日本", "🍕", "\u{10FFFF}", "\u{200B}", "\u{FEFF}", "\u{202E}", "\u{FFFD}", "e\u{301}", "__", "::",
    "<script>", "../", "%0d%0a", "id", "name", "value", "sort", "direction", "desc",
];

pub(crate) fn random_text(rng: &mut Rng) -> String {
    (0..rng.below(10)).map(|_| *rng.pick(PIECES)).collect()
}

/// Edge-case numbers a JSON consumer is likely to mishandle, as JSON values.
pub(crate) fn edge_number(rng: &mut Rng) -> Value {
    let edges: Vec<Value> = vec![
        json!(0),
        json!(-1),
        json!(1),
        json!(i64::MAX),
        json!(i64::MIN),
        json!(u64::MAX),
        json!(0.0),
        json!(-0.0),
        json!(0.1),
        json!(1e308),
        json!(-1e308),
        json!(5e-324),
        json!(1.7976931348623157e308),
        json!(9007199254740993_i64),
    ];
    rng.pick(&edges).clone()
}

/// A JSON value of any shape, to a bounded depth, favoring the wrong type for whatever reads it.
pub(crate) fn random_value(rng: &mut Rng, depth: usize) -> Value {
    let leaf_only = depth >= 3;
    match rng.below(if leaf_only { 6 } else { 8 }) {
        0 => Value::Null,
        1 => Value::Bool(rng.chance(2)),
        2 => edge_number(rng),
        3 | 4 => Value::String(random_text(rng)),
        5 => json!(rng.next() as i64 >> rng.below(63)),
        6 => Value::Array((0..rng.below(4)).map(|_| random_value(rng, depth + 1)).collect()),
        _ => {
            let mut map = Map::new();
            for _ in 0..rng.below(4) {
                map.insert(random_text(rng), random_value(rng, depth + 1));
            }
            Value::Object(map)
        }
    }
}

/// `text` with a few random edits, on char boundaries.
pub(crate) fn mutate_text(rng: &mut Rng, text: &str) -> String {
    let mut chars: Vec<char> = text.chars().collect();
    const JUNK: &[char] = &['{', '}', '[', ']', '"', '\\', ',', ':', '-', '+', '.', 'e', '0', '9', 'n', 't', ' ', '\u{0}', '\n', '%', 'é', '🍕'];
    for _ in 0..1 + rng.below(3) {
        if chars.is_empty() {
            chars.push(*rng.pick(JUNK));
            continue;
        }
        let at = rng.below(chars.len());
        match rng.below(4) {
            0 => {
                chars.remove(at);
            }
            1 => chars.insert(at, *rng.pick(JUNK)),
            2 => chars[at] = *rng.pick(JUNK),
            _ => chars.truncate(at),
        }
    }
    chars.into_iter().collect()
}

/// Raw bytes, valid UTF-8 or not: random, mutated JSON, truncated mid-character, or hostile.
pub(crate) fn random_bytes(rng: &mut Rng) -> Vec<u8> {
    match rng.below(6) {
        0 => (0..rng.below(64)).map(|_| rng.next() as u8).collect(),
        1 => {
            let valid = random_value(rng, 0).to_string();
            mutate_text(rng, &valid).into_bytes()
        }
        2 => {
            let mut bytes = random_value(rng, 0).to_string().into_bytes();
            bytes.extend_from_slice(&[0xff, 0xfe, 0xc0, 0x80, 0xf0, 0x9f]);
            bytes
        }
        3 => "{\"a\":\"🍕\"}".as_bytes()[..rng.below(10)].to_vec(),
        4 => random_text(rng).into_bytes(),
        _ => random_value(rng, 0).to_string().into_bytes(),
    }
}
