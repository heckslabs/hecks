//! [antibody-exempt: rust/src/runtime/voice/phrase_cache.rs —
//!  kernel-floor content-addressed audio store for Voice.PhraseCache.
//!  Hand-rolled sha256 (FIPS 180-4) keeps the crate dep-free in line
//!  with the sibling tts_dispatcher / llm_providers/test substrate
//!  discipline. Retires when the framework-wide kernel-hook registry
//!  (i557) replaces hand-coded :tts wrappers.]
//!
//! PhraseCache — content-addressed mp3 cache
//!
//! `try_hit(text, voice_id, model, speed)` returns `Some(path)` when
//! a cached mp3 already exists for the given tuple ; the caller pipes
//! it straight to mpg123 and skips the ElevenLabs HTTP call.
//!
//! `save(text, voice_id, model, speed, src_path)` copies a freshly
//! rendered mp3 into the cache under its hash key so subsequent
//! Speaks with the same tuple hit. Idempotent — repeated saves of
//! the same tuple overwrite the same target.
//!
//! Cache root resolves `~` to `$HOME` ; default location is
//! `~/.config/miette/audio/phrase_cache/`. The directory is created
//! on demand. The hash key is `sha256(text + "|" + voice_id + "|" +
//! model + "|" + speed)` hex-encoded ; the `|` separators keep
//! `("ab", "c")` distinct from `("a", "bc")`.

use std::path::PathBuf;

/// Cache key for a (text, voice_id, model, speed) tuple. Returned as
/// a 64-char hex string of the sha256 over the canonical join.
pub fn key(text: &str, voice_id: &str, model: &str, speed: &str) -> String {
    let joined = format!("{}|{}|{}|{}", text, voice_id, model, speed);
    sha256_hex(joined.as_bytes())
}

/// Resolve the cache directory, creating it if missing. Returns the
/// absolute path. Errors are surfaced as `Err(reason)` so the
/// caller can fall through to the no-cache path without panicking.
pub fn cache_dir() -> Result<PathBuf, String> {
    let home = std::env::var("HOME").unwrap_or_default();
    let dir = PathBuf::from(format!("{}/.config/miette/audio/phrase_cache", home));
    std::fs::create_dir_all(&dir)
        .map_err(|e| format!("phrase_cache : cannot create {} ({})", dir.display(), e))?;
    Ok(dir)
}

/// Lookup path for the given key. Existence is NOT checked — callers
/// use `try_hit` for the existence-gated variant.
pub fn path_for(key_hex: &str) -> Result<PathBuf, String> {
    Ok(cache_dir()?.join(format!("{}.mp3", key_hex)))
}

/// Cache-hit check. Returns `Some(path)` when a non-trivial mp3 is
/// already cached for the tuple ; `None` otherwise. The size gate
/// (>1024 bytes) mirrors the dispatcher's response-too-small guard
/// so a previous-render error file (small JSON) doesn't masquerade
/// as a cache hit.
pub fn try_hit(text: &str, voice_id: &str, model: &str, speed: &str) -> Option<PathBuf> {
    let k = key(text, voice_id, model, speed);
    let path = path_for(&k).ok()?;
    let meta = std::fs::metadata(&path).ok()?;
    if meta.len() > 1024 { Some(path) } else { None }
}

/// Save a freshly rendered mp3 into the cache under the tuple's hash
/// key. Best-effort : an io error returns Err but the dispatcher
/// can still consider the render itself a success (the audit-named
/// mp3 already played).
pub fn save(
    text: &str, voice_id: &str, model: &str, speed: &str, src_path: &str
) -> Result<PathBuf, String> {
    let k = key(text, voice_id, model, speed);
    let dst = path_for(&k)?;
    std::fs::copy(src_path, &dst)
        .map_err(|e| format!("phrase_cache : copy {} → {} failed ({})", src_path, dst.display(), e))?;
    Ok(dst)
}

// ─── SHA-256 (FIPS 180-4) — same hand-rolled impl as llm_providers/test.rs ─

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

fn sha256_hex(input: &[u8]) -> String {
    let bytes = sha256(input);
    let mut hex = String::with_capacity(64);
    for b in &bytes {
        hex.push_str(&format!("{:02x}", b));
    }
    hex
}

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha256_known_vector() {
        // RFC 6234 test vector : sha256("abc")
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn key_is_deterministic_and_distinct() {
        let k1 = key("Done.", "v1", "eleven_v3", "1.2");
        let k2 = key("Done.", "v1", "eleven_v3", "1.2");
        let k3 = key("Done.", "v1", "eleven_v3", "1.3"); // speed differs
        let k4 = key("Done.", "v2", "eleven_v3", "1.2"); // voice differs
        assert_eq!(k1, k2, "same tuple ⇒ same key");
        assert_ne!(k1, k3, "speed change ⇒ different key");
        assert_ne!(k1, k4, "voice change ⇒ different key");
        assert_eq!(k1.len(), 64, "hex sha256 is 64 chars");
    }

    #[test]
    fn key_separator_prevents_collision() {
        // Without the `|` separator, ("ab", "c", _, _) and
        // ("a", "bc", _, _) would collide. Confirm they don't.
        let k_ab_c = key("ab", "c", "m", "1.0");
        let k_a_bc = key("a", "bc", "m", "1.0");
        assert_ne!(k_ab_c, k_a_bc);
    }

    #[test]
    fn try_hit_returns_none_when_path_missing() {
        // Point HOME at a fresh tempdir so the cache_dir exists but
        // contains no files. Expect None for any tuple.
        let tmp = std::env::temp_dir().join(format!(
            "phrase_cache_miss_{}", std::process::id()
        ));
        std::fs::create_dir_all(&tmp).unwrap();
        std::env::set_var("HOME", &tmp);
        let hit = try_hit("never-rendered", "v1", "m", "1.0");
        assert!(hit.is_none(), "no file ⇒ no hit");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn save_then_try_hit_round_trip() {
        let tmp = std::env::temp_dir().join(format!(
            "phrase_cache_rt_{}", std::process::id()
        ));
        std::fs::create_dir_all(&tmp).unwrap();
        std::env::set_var("HOME", &tmp);
        // Write a >1024-byte fake mp3 source. The cache copies it
        // under the hash key ; try_hit must then return its path.
        let src = tmp.join("fake_render.mp3");
        std::fs::write(&src, vec![0u8; 2048]).unwrap();
        let saved = save("Done.", "v1", "m", "1.2", src.to_str().unwrap()).unwrap();
        assert!(saved.exists(), "saved file exists");
        let hit = try_hit("Done.", "v1", "m", "1.2");
        assert!(hit.is_some(), "post-save try_hit returns Some");
        assert_eq!(hit.unwrap(), saved);
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
