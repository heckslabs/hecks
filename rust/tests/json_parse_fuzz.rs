// Seeded, std-only fuzz of the kernel's hand-written JSON parser (`Json::parse`), the boundary
// every WASM/CLI argument crosses. Properties: it never panics, never hangs, refuses instead of
// overflowing the stack, and whatever it accepts it can write back as JSON it accepts again.
//
// Deterministic: every case derives from a fixed seed, so a failure names the seed that replays it.
// Run more seeds with `JSON_FUZZ_SEEDS=2000 cargo test --test json_parse_fuzz`.

use rust::kernel::Json;
use std::sync::mpsc;
use std::time::Duration;

/// xorshift64*: no dependency, and a printable seed is the whole reproduction.
struct Rng(u64);

impl Rng {
    fn new(seed: u64) -> Self {
        Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1)
    }

    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next() % n.max(1) as u64) as usize
    }

    fn pick<'a, T>(&mut self, items: &'a [T]) -> &'a T {
        &items[self.below(items.len())]
    }
}

fn seeds() -> u64 {
    std::env::var("JSON_FUZZ_SEEDS").ok().and_then(|v| v.parse().ok()).unwrap_or(300)
}

/// Runs `f` on a thread with a 2 MiB stack (a test thread's default), failing on a panic or when
/// it has not finished within `limit`. A stack overflow aborts the whole binary, which also fails.
fn guarded<T: Send + 'static>(label: &str, limit: Duration, f: impl FnOnce() -> T + Send + 'static) -> T {
    let (tx, rx) = mpsc::channel();
    let handle = std::thread::Builder::new().stack_size(2 * 1024 * 1024).spawn(move || {
        let _ = tx.send(f());
    });
    let handle = handle.expect("spawn");
    match rx.recv_timeout(limit) {
        Ok(value) => {
            handle.join().expect("worker joined");
            value
        }
        Err(mpsc::RecvTimeoutError::Timeout) => panic!("{label}: no answer within {limit:?} (hang)"),
        Err(mpsc::RecvTimeoutError::Disconnected) => {
            let panic = handle.join().expect_err("worker dropped its sender without answering");
            let message = panic.downcast_ref::<String>().cloned().or_else(|| panic.downcast_ref::<&str>().map(|s| s.to_string()));
            panic!("{label}: panicked: {}", message.unwrap_or_default())
        }
    }
}

const SECONDS: Duration = Duration::from_secs(20);

/// A random document `Json::parse` is expected to accept, built from the writer's own output
/// shapes so the mutators below start from something mostly valid.
fn random_json(rng: &mut Rng, depth: usize) -> Json {
    let leaf_only = depth >= 4;
    match rng.below(if leaf_only { 6 } else { 8 }) {
        0 => Json::Null,
        1 => Json::Bool(rng.below(2) == 0),
        2 => Json::int(rng.next() as i64 >> rng.below(60)),
        3 => Json::float((rng.next() as i64 >> 20) as f64 / 7.0),
        4 | 5 => Json::str(random_string(rng)),
        6 => Json::Array((0..rng.below(4)).map(|_| random_json(rng, depth + 1)).collect()),
        _ => Json::Object((0..rng.below(4)).map(|_| (random_string(rng), random_json(rng, depth + 1))).collect()),
    }
}

/// Text that stresses escaping: quotes, backslashes, control characters, NUL, astral planes,
/// combining marks, right-to-left and the replacement character.
fn random_string(rng: &mut Rng) -> String {
    const PIECES: &[&str] = &[
        "a", "Z", " ", "\"", "\\", "/", "\n", "\t", "\r", "\u{0}", "\u{1f}", "\u{7f}", "é", "ü", "日本", "🍕", "\u{10FFFF}",
        "\u{200B}", "\u{FEFF}", "\u{202E}", "\u{FFFD}", "e\u{301}", "\\u0041", "\\ud83c", "{", "}", "[", "]", ":", ",",
    ];
    (0..rng.below(8)).map(|_| *rng.pick(PIECES)).collect()
}

/// One small random damage to `text`, on char boundaries so the result is still a `&str`.
fn mutate(rng: &mut Rng, text: &str) -> String {
    let mut chars: Vec<char> = text.chars().collect();
    const JUNK: &[char] = &['{', '}', '[', ']', '"', '\\', ',', ':', '-', '+', '.', 'e', 'E', '0', '9', 'n', 't', 'f', 'u', ' ', '\u{0}', '\n', 'é', '🍕'];
    for _ in 0..1 + rng.below(3) {
        if chars.is_empty() {
            chars.push(*rng.pick(JUNK));
            continue;
        }
        let at = rng.below(chars.len());
        match rng.below(5) {
            0 => {
                chars.remove(at);
            }
            1 => chars.insert(at, *rng.pick(JUNK)),
            2 => chars[at] = *rng.pick(JUNK),
            3 => chars.truncate(at),
            _ => {
                let end = (at + rng.below(6)).min(chars.len());
                let slice: Vec<char> = chars[at..end].to_vec();
                chars.splice(at..at, slice);
            }
        }
    }
    chars.into_iter().collect()
}

/// What an accepted document must satisfy: it writes back as JSON, and that JSON parses to an
/// equal value (`NaN` has no equal, so a non-finite number must never have been accepted).
fn check_round_trip(label: &str, parsed: &Json) {
    let written = parsed.to_json_string();
    let again = Json::parse(&written).unwrap_or_else(|e| panic!("{label}: wrote {written:?}, which no longer parses: {e}"));
    assert_eq!(&again, parsed, "{label}: write-then-parse changed the value ({written:?})");
}

#[test]
fn valid_documents_round_trip_and_every_mutation_is_answered_without_a_panic() {
    for seed in 0..seeds() {
        let mut rng = Rng::new(seed);
        let document = random_json(&mut rng, 0);
        let label = format!("seed {seed}");
        guarded(&label, SECONDS, move || {
            let mut rng = Rng::new(seed ^ 0xABCD);
            let text = document.to_json_string();
            // Strings are not compared: a `\ud83c` half-pair in the source reads back as U+FFFD.
            let parsed = Json::parse(&text).unwrap_or_else(|e| panic!("seed {seed}: own output {text:?} refused: {e}"));
            check_round_trip(&format!("seed {seed} (own output)"), &parsed);
            for _ in 0..40 {
                let damaged = mutate(&mut rng, &text);
                if let Ok(accepted) = Json::parse(&damaged) {
                    check_round_trip(&format!("seed {seed} accepted {damaged:?}"), &accepted);
                }
            }
        });
    }
}

#[test]
fn arbitrary_character_soup_never_panics() {
    for seed in 0..seeds() {
        guarded(&format!("seed {seed}"), SECONDS, move || {
            let mut rng = Rng::new(seed ^ 0x5EED);
            let alphabet: Vec<char> = "{}[]\",:\\ -+.eE0123456789ntrufals/bé🍕\u{0}\u{1b}\u{a0}\u{2028}".chars().collect();
            for _ in 0..50 {
                let text: String = (0..rng.below(64)).map(|_| *rng.pick(&alphabet)).collect();
                if let Ok(accepted) = Json::parse(&text) {
                    check_round_trip(&format!("seed {seed} accepted {text:?}"), &accepted);
                }
            }
        });
    }
}

#[test]
fn the_empty_and_whitespace_only_inputs_are_refused() {
    for text in ["", " ", "\n\t\r ", "\u{a0}", "\u{feff}"] {
        assert!(Json::parse(text).is_err(), "{text:?} holds no value");
    }
}

#[test]
fn nesting_past_the_limit_is_refused_not_a_stack_overflow() {
    for (open, close) in [("[", "]"), ("{\"k\":", "}")] {
        for depth in [127, 128, 129, 1_000, 200_000] {
            let text = format!("{}1{}", open.repeat(depth), close.repeat(depth));
            let answer = guarded(&format!("{open} x {depth}"), SECONDS, move || Json::parse(&text).map(|_| ()));
            if depth > 128 {
                let error = answer.expect_err("a document nested past the limit must be refused");
                assert!(error.contains("nests deeper"), "{open} x {depth}: unhelpful refusal {error:?}");
            }
        }
    }
}

#[test]
fn an_unclosed_run_of_openers_is_refused_without_overflowing() {
    let text = "[".repeat(500_000);
    guarded("500k openers", SECONDS, move || assert!(Json::parse(&text).is_err()));
}

#[test]
fn a_wide_document_is_accepted_in_linear_time() {
    let array = format!("[{}]", vec!["1"; 200_000].join(","));
    let object = format!("{{{}}}", (0..50_000).map(|i| format!("\"k{i}\":{i}")).collect::<Vec<_>>().join(","));
    guarded("wide", SECONDS, move || {
        assert!(Json::parse(&array).is_ok());
        assert!(Json::parse(&object).is_ok());
    });
}

#[test]
fn a_very_long_string_and_a_very_long_number_are_answered() {
    let long_string = format!("\"{}\"", "x".repeat(8_000_000));
    let long_digits = "9".repeat(2_000_000);
    guarded("long scalars", SECONDS, move || {
        assert_eq!(Json::parse(&long_string).unwrap().as_str().map(str::len), Some(8_000_000));
        // Past f64's range, a plain integer keeps its digits; it must not panic or become `inf`.
        if let Ok(parsed) = Json::parse(&long_digits) {
            assert_eq!(parsed.to_json_string(), long_digits);
        }
    });
}

#[test]
fn number_edge_cases_are_refused_or_written_back_as_valid_json() {
    let cases = [
        "-", "-0", "0", "00", "-00", "01", "1.", ".5", "-.5", "1.e3", "1e", "1e+", "1e-", "1E5", "1e5", "1e308", "1e309", "-1e309", "1e999999999999",
        "1e-999999999999", "4.9e-324", "2.2250738585072014e-308", "1.7976931348623157e308", "9223372036854775807", "9223372036854775808", "-9223372036854775808",
        "-9223372036854775809", "18446744073709551616", "0.1e1", "123456789012345678901234567890", "-123456789012345678901234567890",
        "1_000", "0x10", "NaN", "Infinity", "-Infinity", "inf", "--1", "+1", "1.2.3", "1e5e5",
    ];
    for text in cases {
        guarded(text, SECONDS, move || {
            if let Ok(parsed) = Json::parse(text) {
                let written = parsed.to_json_string();
                assert!(!written.contains("inf") && !written.contains("NaN"), "{text:?} was accepted and written as {written:?}, which is not JSON");
                check_round_trip(&format!("{text:?}"), &parsed);
            }
        });
    }
}

#[test]
fn infinity_from_an_overflowing_literal_is_refused() {
    // `1e309` is finite JSON syntax whose f64 value is infinite; writing it back would emit `inf`.
    for text in ["1e309", "-1e309", "1.5e400", "[1e999]", "{\"a\":1e999}"] {
        assert!(Json::parse(text).is_err(), "{text:?} must be refused, not parsed to infinity");
    }
}

#[test]
fn string_escape_edge_cases_never_panic() {
    let cases = [
        r#""\u""#, r#""\u0""#, r#""\u00""#, r#""\u000""#, r#""\u0000""#, r#""\ud800""#, r#""\udc00""#, r#""🍕""#, r#""\ud83cA""#, r#""\uZZZZ""#,
        r#""\u+041""#, r#""\x41""#, r#""\"#, r#""\""#, "\"\\", "\"abc", "\"\u{0}\"", "\"\n\"", "\"\u{1f}\"", "\"\u{10FFFF}\"", "\"\u{FEFF}\"", "\"\\u0041\\u0042\"",
    ];
    for text in cases {
        guarded(text, SECONDS, move || {
            if let Ok(parsed) = Json::parse(text) {
                check_round_trip(&format!("{text:?}"), &parsed);
            }
        });
    }
}

#[test]
fn structural_edge_cases_are_refused_or_round_trip() {
    let cases = [
        "{", "}", "[", "]", "{]", "[}", "{,}", "[,]", "[1,]", "{\"a\":1,}", "{\"a\"}", "{\"a\":}", "{:1}", "{1:1}", "{\"a\" 1}", "[1 2]", "{\"a\":1 \"b\":2}",
        "{\"a\":1,\"a\":2}", "{\"a\":1,\"a\":1,\"a\":1}", "[[],[[]],{}]", "{\"\":\"\"}", "nul", "nulll", "tru", "truefalse", "True", "NULL", "'a'", "{'a':1}",
        "// c\n1", "/* c */1", "1 // c", "[1]]", "{}{}", "1 2", "\u{0}", "\u{feff}{}",
    ];
    for text in cases {
        guarded(text, SECONDS, move || {
            if let Ok(parsed) = Json::parse(text) {
                check_round_trip(&format!("{text:?}"), &parsed);
            }
        });
    }
}

#[test]
fn duplicate_keys_keep_every_pair_and_lookup_is_first_wins() {
    let parsed = Json::parse("{\"a\":1,\"a\":2}").unwrap();
    assert_eq!(parsed.to_json_string(), "{\"a\":1,\"a\":2}", "the writer must not silently drop a duplicate");
    assert_eq!(parsed.get("a"), Some(&Json::int(1)));
}

#[test]
fn accessors_never_panic_on_any_parsed_shape() {
    for seed in 0..seeds() {
        guarded(&format!("seed {seed}"), SECONDS, move || {
            let mut rng = Rng::new(seed ^ 0xACE);
            let value = random_json(&mut rng, 0);
            let _ = (value.as_str(), value.as_i64(), value.as_f64(), value.as_bool(), value.as_array());
            let _ = (value.get("a"), value.dig("a.b.c"), value.dig(""), value.dig("..."), value.inspect(), value.describe(), value.ruby_to_s());
            let _ = (value.to_id_component(), value.to_id_component_lenient(), value.unknown_keys(&["a"]));
            let _ = (value.coerce_single_field("a"), value.with_aliases(&[("a", "b")]), Json::overlay(&value, &random_json(&mut rng, 0)));
            let _ = (value.expect_value_object_shape("field", "Type"), value.require("a", "Struct"));
        });
    }
}
