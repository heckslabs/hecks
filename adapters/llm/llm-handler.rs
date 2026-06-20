//! llm-handler (Rust) — a standalone, COMPILED out-of-process `:llm` ADAPTER
//! program. The verdict-capturing sibling of the tts-handler : where tts is
//! fire-and-forget and self-acks, THIS handler emits a VERDICT (`response_text`)
//! the primary-adapter wait threads into the success command. The drainer (NOT
//! this program) dispatches the verdict + marks the delivery delivered.
//!
//! TestProvider parity — deterministic, no network. Mirrors
//! rust/src/runtime/llm_providers/test.rs : SHA-256(prompt) keys a fixture
//! lookup ; a miss yields the same lenient placeholder
//! `[test-provider:unknown-prompt sha256=<digest>]`. Same SHA = same answer as
//! the in-process path, so gate-ON == gate-OFF.
//!
//! ADAPTER-HOST CONTRACT (mirrors stripe-handler / the run_host exec protocol) :
//!   * STDIN : the trigger event payload as JSON (carries `prompt`).
//!   * ENV   : the adapter config the wait folds in from .world under the
//!             canonical <FAMILY>_<FIELD> names (LLM_BACKEND, LLM_MODEL,
//!             LLM_MAX_TOKENS, LLM_PROMPT_TEMPLATE). Plus LLM_FIXTURES — an
//!             optional path to a TSV fixtures file (sha256-hex<TAB>response).
//!   * STDOUT: `response_text=<completion>` (the family's `produces` contract).
//!   * EXIT  : 0 = success branch (verdict = success_command), non-zero =
//!             failure branch (verdict = failure_command).
//!
//! Build (standalone, zero deps) :
//!   rustc -O adapters/llm/llm-handler.rs -o adapters/llm/llm-handler

use std::io::Read;

fn env_opt(key: &str) -> Option<String> {
    std::env::var(key).ok().filter(|v| !v.is_empty())
}

/// Extract a JSON string value for `key` from `src`, decoding standard
/// escapes. UTF-8 safe. Minimal by design — the payload is a flat object.
fn json_string_field(src: &str, key: &str) -> Option<String> {
    let pat = format!("\"{}\"", key);
    let start = src.find(&pat)? + pat.len();
    let rest = &src[start..];
    let colon = rest.find(':')?;
    let after = &rest[colon + 1..];
    let q = after.find('"')?;
    let mut out = String::new();
    let mut chars = after[q + 1..].chars();
    while let Some(c) = chars.next() {
        match c {
            '\\' => match chars.next() {
                Some('"') => out.push('"'),
                Some('\\') => out.push('\\'),
                Some('/') => out.push('/'),
                Some('n') => out.push('\n'),
                Some('t') => out.push('\t'),
                Some('r') => out.push('\r'),
                Some('b') => out.push('\u{08}'),
                Some('f') => out.push('\u{0C}'),
                Some('u') => {
                    let hex: String = chars.by_ref().take(4).collect();
                    if let Ok(n) = u32::from_str_radix(&hex, 16) {
                        if let Some(ch) = char::from_u32(n) {
                            out.push(ch);
                        }
                    }
                }
                Some(other) => out.push(other),
                None => break,
            },
            '"' => return Some(out),
            _ => out.push(c),
        }
    }
    None
}

/// SHA-256 hex digest — byte-identical to TestProvider::hash_for so the OOP
/// fixture key matches the in-process one.
fn hash_for(prompt: &str) -> String {
    let bytes = sha256(prompt.as_bytes());
    let mut hex = String::with_capacity(64);
    for b in &bytes {
        hex.push_str(&format!("{:02x}", b));
    }
    hex
}

const K: [u32; 64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

fn sha256(input: &[u8]) -> [u8; 32] {
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ];
    let bit_len = (input.len() as u64).wrapping_mul(8);
    let mut padded: Vec<u8> = input.to_vec();
    padded.push(0x80);
    while padded.len() % 64 != 56 { padded.push(0); }
    padded.extend_from_slice(&bit_len.to_be_bytes());
    for chunk in padded.chunks(64) {
        let mut w = [0u32; 64];
        for i in 0..16 {
            w[i] = u32::from_be_bytes([chunk[i*4], chunk[i*4+1], chunk[i*4+2], chunk[i*4+3]]);
        }
        for i in 16..64 {
            let s0 = w[i-15].rotate_right(7) ^ w[i-15].rotate_right(18) ^ (w[i-15] >> 3);
            let s1 = w[i-2].rotate_right(17) ^ w[i-2].rotate_right(19) ^ (w[i-2] >> 10);
            w[i] = w[i-16].wrapping_add(s0).wrapping_add(w[i-7]).wrapping_add(s1);
        }
        let (mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh) =
            (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7]);
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ (!e & g);
            let t1 = hh.wrapping_add(s1).wrapping_add(ch).wrapping_add(K[i]).wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let mj = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(mj);
            hh = g; g = f; f = e;
            e = d.wrapping_add(t1);
            d = c; c = b; b = a;
            a = t1.wrapping_add(t2);
        }
        h[0] = h[0].wrapping_add(a); h[1] = h[1].wrapping_add(b);
        h[2] = h[2].wrapping_add(c); h[3] = h[3].wrapping_add(d);
        h[4] = h[4].wrapping_add(e); h[5] = h[5].wrapping_add(f);
        h[6] = h[6].wrapping_add(g); h[7] = h[7].wrapping_add(hh);
    }
    let mut out = [0u8; 32];
    for (i, w) in h.iter().enumerate() {
        out[i*4..i*4+4].copy_from_slice(&w.to_be_bytes());
    }
    out
}

/// Load a flat TSV fixtures file (sha256-hex<TAB>response). Blank lines and
/// `#` comments skipped. Missing file -> empty map (lenient miss applies).
fn load_fixtures(path: &str) -> std::collections::HashMap<String, String> {
    let mut out = std::collections::HashMap::new();
    if let Ok(contents) = std::fs::read_to_string(path) {
        for line in contents.lines() {
            let l = line.trim_end_matches('\r');
            if l.is_empty() || l.starts_with('#') { continue; }
            if let Some((digest, body)) = l.split_once('\t') {
                let d = digest.trim().to_string();
                if d.len() == 64 && d.chars().all(|c| c.is_ascii_hexdigit()) {
                    out.insert(d, body.to_string());
                }
            }
        }
    }
    out
}

fn main() {
    // prompt : from the event payload on stdin.
    let mut raw = String::new();
    let _ = std::io::stdin().read_to_string(&mut raw);
    let prompt = json_string_field(&raw, "prompt").unwrap_or_default();

    let digest = hash_for(&prompt);
    let fixtures = env_opt("LLM_FIXTURES")
        .map(|p| load_fixtures(&p))
        .unwrap_or_default();
    let response_text = match fixtures.get(&digest) {
        Some(text) => text.clone(),
        None => format!("[test-provider:unknown-prompt sha256={}]", digest),
    };

    // The family's `produces :response_text` contract — one k=v verdict line.
    println!("response_text={}", response_text);
    std::process::exit(0);
}
