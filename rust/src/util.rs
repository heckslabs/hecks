//! Util — small dependency-free helpers that belong to no single storage
//! or domain concern.
//!
//! `snake_case` (a name → filesystem-/identifier-safe segment) and
//! `uuid_v4` (a dependency-free random id) lived in `heki.rs` until
//! 2026-06-10, when they were evicted : a module named after a storage
//! format should not own generic string and id utilities. Both sit at
//! the kernel floor beside `clock` ; `heki` imports them, not the
//! reverse.
//!
//! Usage:
//!   let seg = util::snake_case("MietteBody"); // "miette_body"
//!   let id  = util::uuid_v4();                 // "…-4…-…" (v4)

#[cfg(not(target_arch = "wasm32"))]
use std::fs;
#[cfg(not(target_arch = "wasm32"))]
use std::io::Read as IoRead;

// `snake_case` lived here until it turned out to be one of SEVEN spellings of
// the same rule, under three different semantics. It was the naive one — an
// underscore before every capital, so `ATMCard` came out `a_t_m_card` while
// the parser and Ruby both said `atm_card`, and an aggregate was therefore
// stored at one path and addressed at another. The rule now lives in
// `crate::naming`, which is a DOMAIN concern and not a utility one: see
// naming.rs.

/// Generate a UUID v4 (random) without external dependencies.
pub fn uuid_v4() -> String {
    let mut bytes = [0u8; 16];

    #[cfg(not(target_arch = "wasm32"))]
    {
        // Host : pull system entropy via /dev/urandom ; fall back
        // to hashing the current time if that fails (e.g. on
        // hardened sandboxes).
        if let Ok(mut f) = fs::File::open("/dev/urandom") {
            let _ = f.read_exact(&mut bytes);
        } else {
            let seed = crate::clock::now_duration().as_nanos();
            for (i, b) in bytes.iter_mut().enumerate() {
                *b = ((seed >> (i * 4)) & 0xff) as u8;
            }
        }
    }
    #[cfg(target_arch = "wasm32")]
    {
        // WASM : no /dev/urandom in the CF Worker runtime. Route
        // through getrandom::getrandom which, with the `js` feature
        // enabled in Cargo.toml, calls JS crypto.getRandomValues —
        // the same CSPRNG the Worker runtime exposes to the JS side.
        // Crypto-grade entropy without /dev/urandom. Fall back to
        // time-seeded bytes only if the getrandom call itself
        // fails (it shouldn't, on CF Workers).
        if getrandom::getrandom(&mut bytes).is_err() {
            let seed = crate::clock::now_duration().as_nanos();
            for (i, b) in bytes.iter_mut().enumerate() {
                let chunk = (seed >> ((i * 13) % 128)) ^ (seed >> ((i * 7) % 128));
                *b = (chunk & 0xff) as u8;
            }
        }
    }
    // Set version 4 and variant bits
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    // The snake_case tests moved to naming.rs with the rule. One of them —
    // `assert_eq!(snake_case("ABCD"), "a_b_c_d")` — was PINNING the divergence
    // as though it were intended behaviour, which is how the disagreement with
    // Ruby survived a green suite for as long as it did. It is not carried
    // over: Ruby answers "abcd", and Ruby holds the semantics.

    #[test]
    fn uuid_v4_is_well_formed() {
        let id = uuid_v4();
        assert_eq!(id.len(), 36);
        assert_eq!(id.chars().filter(|c| *c == '-').count(), 4);
        // version nibble is 4
        assert_eq!(id.as_bytes()[14], b'4');
    }
}
