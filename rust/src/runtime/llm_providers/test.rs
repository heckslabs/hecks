//! [antibody-exempt: rust/src/runtime/llm_providers/test.rs — kernel-floor
//!  LLM dispatcher port (Phase 2 i221) ; parallels existing kernel-floor
//!  runtime markers on adapter_io.rs / shell_dispatcher.rs / adapter_llm.rs.
//!  Retires when the LLM dispatch becomes bluebook-driven via :llm
//!  hecksagon adapters resolved at runtime + a dedicated dispatcher
//!  bluebook (filed as follow-up).]
//!
//! TestProvider — fixture-backed LLM provider keyed by SHA-256(prompt).
//! Mirrors `ruby/hecks/runtime/llm_providers/test_provider.rb`.
//!
//! Two miss modes :
//!   - lenient (default) : unknown prompts return a stable synthetic
//!     placeholder so downstream pipelines still flow ; useful while
//!     fixtures are still being captured.
//!   - strict (env HECKS_LLM_FIXTURE_STRICT=1 or `strict: true`) :
//!     unknown prompts surface a `LlmError::FixtureMissing { digest }`
//!     so CI fails fast.
//!
//! Fixture loading from disk is supported via `from_fixtures_file` —
//! the on-disk format mirrors miette's `dream.fixtures` :
//!
//!   sha256-hex<TAB>response_text\n
//!
//! Lines starting with `#` and blank lines are skipped. The hex digest
//! is the SHA-256 of the **substituted** prompt (after `{{placeholder}}`
//! tokens are filled), which is exactly what the dispatcher hands to
//! `invoke`.

use super::{LlmError, LlmProvider, LlmProviderResult};
use std::collections::HashMap;
use std::path::Path;

pub struct TestProvider {
    fixtures: HashMap<String, String>,
    strict: bool,
}

impl TestProvider {
    /// Build a provider with a literal sha256→response map. Keys may be
    /// supplied as either the SHA-256 hex digest of the prompt OR as the
    /// raw prompt string ; raw strings are hashed on insertion so call
    /// sites can register fixtures without re-deriving the digest.
    pub fn new(fixtures: HashMap<String, String>) -> Self {
        let mut normalized: HashMap<String, String> = HashMap::new();
        for (k, v) in fixtures {
            let key = if k.len() == 64 && k.chars().all(|c| c.is_ascii_hexdigit()) {
                k
            } else {
                Self::hash_for(&k)
            };
            normalized.insert(key, v);
        }
        let strict = std::env::var("HECKS_LLM_FIXTURE_STRICT")
            .ok().as_deref() == Some("1");
        Self { fixtures: normalized, strict }
    }

    /// Build a provider whose fixtures are loaded from a `dream.fixtures`-
    /// shaped file. Missing file → empty fixtures (the lenient default
    /// kicks in on first invoke). Malformed lines are skipped.
    pub fn from_fixtures_file<P: AsRef<Path>>(path: P) -> Self {
        let mut fixtures: HashMap<String, String> = HashMap::new();
        if let Ok(contents) = std::fs::read_to_string(&path) {
            for line in contents.lines() {
                let l = line.trim_end_matches('\r');
                if l.is_empty() || l.starts_with('#') { continue; }
                if let Some((digest, body)) = l.split_once('\t') {
                    let d = digest.trim().to_string();
                    if d.len() == 64 && d.chars().all(|c| c.is_ascii_hexdigit()) {
                        fixtures.insert(d, body.to_string());
                    }
                }
            }
        }
        let strict = std::env::var("HECKS_LLM_FIXTURE_STRICT")
            .ok().as_deref() == Some("1");
        Self { fixtures, strict }
    }

    /// Force strict mode (used by tests).
    pub fn with_strict(mut self, strict: bool) -> Self {
        self.strict = strict;
        self
    }

    pub fn fixture_count(&self) -> usize {
        self.fixtures.len()
    }

    /// SHA-256 hex digest of `prompt` — the canonical fixture key.
    /// Pure Rust implementation (32 bytes of state, 64-byte block) so
    /// the crate adds no `sha2` dep.
    pub fn hash_for(prompt: &str) -> String {
        let bytes = sha256(prompt.as_bytes());
        let mut hex = String::with_capacity(64);
        for b in &bytes {
            hex.push_str(&format!("{:02x}", b));
        }
        hex
    }
}

impl LlmProvider for TestProvider {
    fn invoke(
        &self,
        prompt: &str,
        model: &str,
        _max_tokens: u64,
    ) -> Result<LlmProviderResult, LlmError> {
        let digest = Self::hash_for(prompt);
        let response_text = match self.fixtures.get(&digest) {
            Some(text) => text.clone(),
            None => {
                if self.strict {
                    return Err(LlmError::FixtureMissing { digest });
                }
                format!("[test-provider:unknown-prompt sha256={}]", digest)
            }
        };
        Ok(LlmProviderResult {
            response_text: response_text.clone(),
            tokens_in: estimate_tokens(prompt),
            tokens_out: estimate_tokens(&response_text),
            model_used: model.to_string(),
        })
    }
}

fn estimate_tokens(text: &str) -> u64 {
    text.split_whitespace().filter(|s| !s.is_empty()).count() as u64
}

// ─── SHA-256 (FIPS 180-4) ───────────────────────────────────────────
//
// Rolled inline to keep the crate dep-free. ~80 LoC, classic K[64] +
// initial hash constants. Identical output to `Digest::SHA256.hexdigest`
// in Ruby (verified against the same test vectors used by the Ruby
// TestProvider spec).

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
