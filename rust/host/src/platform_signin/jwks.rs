//! The issuer's public keys: parsing its key set, and a cache that fetches it politely.
//!
//! ## Keys are named by what they are
//!
//! Every key is indexed by the RFC 7638 thumbprint computed from its own material, never by the
//! `kid` the document claims. A token's `kid` header is then only a way to ask "the key whose
//! thumbprint is this"; a document that labels one key with another's identifier cannot make a
//! token verify under the wrong key. Only `OKP` / `Ed25519` keys with a 32-byte canonical `x` and
//! no
//! private member `d` are kept; everything else in the document is dropped and reported.
//!
//! ## No network here
//!
//! The cache asks an injected [`JwksFetcher`] for the document body. The real HTTP implementation
//! (timeout, body cap, no redirects) belongs to whoever wires this module in.

use std::collections::HashMap;
use std::sync::Mutex;

use sha2::{Digest, Sha256};

use super::jws::{decode_base64url, encode_base64url};
use super::strict_json::{self, Json};

/// Seconds a fetched key set is served before it is considered stale.
pub const DEFAULT_TTL_SECONDS: i64 = 300;
/// The fewest seconds between two fetch attempts, however many unknown keys arrive.
pub const DEFAULT_MIN_REFETCH_SECONDS: i64 = 30;
/// The longest time to live a fetcher's hint can stretch the cache to.
pub const MAX_TTL_SECONDS: i64 = 3600;
/// The size of an Ed25519 public key in bytes.
pub const ED25519_PUBLIC_KEY_BYTES: usize = 32;

/// An Ed25519 public key the issuer publishes, kept as its canonical `x` member.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerifyingKey {
    x: String,
}

impl VerifyingKey {
    /// Builds a key from the JWK `x` member, or `None` unless it is canonical base64url of 32
    /// bytes.
    pub fn from_x(x: &str) -> Option<Self> {
        let raw = decode_base64url(x)?;
        (raw.len() == ED25519_PUBLIC_KEY_BYTES).then(|| Self { x: x.to_string() })
    }

    /// Returns the `x` member, canonical unpadded base64url.
    pub fn x(&self) -> &str {
        &self.x
    }

    /// Returns the RFC 7638 thumbprint of this key, which is its identifier.
    pub fn thumbprint(&self) -> String {
        thumbprint(&self.x)
    }
}

/// Computes the RFC 7638 thumbprint of an Ed25519 key from its `x` member.
///
/// The thumbprint is the unpadded base64url SHA-256 of the JSON object with members `crv`, `kty`
/// and `x`, in that lexicographic order, with no whitespace.
pub fn thumbprint(x: &str) -> String {
    let canonical = format!(r#"{{"crv":"Ed25519","kty":"OKP","x":"{x}"}}"#);
    encode_base64url(&Sha256::digest(canonical.as_bytes()))
}

/// Why one entry of a key set was not kept.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyRefusal {
    NotAnObject,
    NotOkp,
    NotEd25519,
    BadX,
    CarriesPrivateKey,
}

/// What a key set document held.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct ParsedKeys {
    /// The usable keys, by computed thumbprint.
    pub keys: HashMap<String, VerifyingKey>,
    /// One entry per document entry that was dropped.
    pub refused: Vec<KeyRefusal>,
}

/// A key set document that could not be read at all.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct JwksMalformed;

/// Reads a key set document.
///
/// # Errors
///
/// Returns [`JwksMalformed`] when the body is not one strict JSON object (a repeated key counts) or
/// has no `keys` array. Individual bad entries are not errors: they are dropped and listed in
/// [`ParsedKeys::refused`].
pub fn parse_jwks(body: &str) -> Result<ParsedKeys, JwksMalformed> {
    let document = strict_json::parse_object(body.as_bytes()).ok_or(JwksMalformed)?;
    let Some(Json::Array(entries)) = document.get("keys") else {
        return Err(JwksMalformed);
    };
    let mut parsed = ParsedKeys::default();
    for entry in entries {
        match key_from_entry(entry) {
            Ok(key) => {
                parsed.keys.insert(key.thumbprint(), key);
            }
            Err(refusal) => parsed.refused.push(refusal),
        }
    }
    Ok(parsed)
}

fn key_from_entry(entry: &Json) -> Result<VerifyingKey, KeyRefusal> {
    let Json::Object(jwk) = entry else {
        return Err(KeyRefusal::NotAnObject);
    };
    // A private member means the issuer published a secret; the entry is never trusted or indexed.
    if jwk.get("d").is_some() {
        return Err(KeyRefusal::CarriesPrivateKey);
    }
    if jwk.get_str("kty") != Some("OKP") {
        return Err(KeyRefusal::NotOkp);
    }
    if jwk.get_str("crv") != Some("Ed25519") {
        return Err(KeyRefusal::NotEd25519);
    }
    jwk.get_str("x")
        .and_then(VerifyingKey::from_x)
        .ok_or(KeyRefusal::BadX)
}

/// A failed attempt to get the key set document. It carries no detail on purpose.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FetchFailed;

/// The one thing the cache needs from the network: the key set document's body.
pub trait JwksFetcher: Send + Sync {
    /// Fetches the issuer's key set document.
    ///
    /// # Errors
    ///
    /// Returns [`FetchFailed`] for any failure; the cache treats every failure alike.
    fn fetch(&self) -> Result<String, FetchFailed>;

    /// How long the issuer allows the last fetched document to be cached, in seconds, if it said.
    ///
    /// The cache honours it between its refetch interval and [`MAX_TTL_SECONDS`]; `None` keeps the
    /// cache's own time to live.
    fn ttl_hint(&self) -> Option<i64> {
        None
    }
}

/// Where a verifier gets the public key for a token's `kid`.
pub trait KeySource {
    /// Returns the key whose thumbprint is `kid`, as of `now` (Unix seconds).
    fn key_for(&self, kid: &str, now: i64) -> Option<VerifyingKey>;
}

#[derive(Default)]
struct CacheState {
    keys: HashMap<String, VerifyingKey>,
    fetched_at: Option<i64>,
    attempted_at: Option<i64>,
}

/// A key set cache with a time to live and a rate-limited refetch on an unknown key.
///
/// An unknown `kid` causes at most one fetch per minimum interval, however many unknown ones
/// arrive, and a failed fetch counts as an attempt: someone spraying random identifiers must not
/// turn the verifier into a fetch amplifier. A failed fetch leaves the old keys to age out at their
/// time to live.
pub struct JwksCache<F: JwksFetcher> {
    fetcher: F,
    ttl_seconds: i64,
    min_refetch_seconds: i64,
    state: Mutex<CacheState>,
}

impl<F: JwksFetcher> JwksCache<F> {
    /// Builds a cache with the default time to live (300 s) and refetch interval (30 s).
    pub fn new(fetcher: F) -> Self {
        Self::with_timing(fetcher, DEFAULT_TTL_SECONDS, DEFAULT_MIN_REFETCH_SECONDS)
    }

    /// Builds a cache with explicit timing, in seconds.
    pub fn with_timing(fetcher: F, ttl_seconds: i64, min_refetch_seconds: i64) -> Self {
        Self {
            fetcher,
            ttl_seconds,
            min_refetch_seconds,
            state: Mutex::new(CacheState::default()),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, CacheState> {
        // The state is only ever replaced whole, so a panic elsewhere cannot leave it half-written.
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn is_stale(&self, state: &CacheState, now: i64) -> bool {
        state
            .fetched_at
            .is_none_or(|fetched| now.saturating_sub(fetched) >= self.ttl_seconds)
    }

    fn refresh_due(&self, state: &CacheState, kid: &str, now: i64) -> bool {
        let Some(attempted) = state.attempted_at else {
            return true;
        };
        let wanted = self.is_stale(state, now) || !state.keys.contains_key(kid);
        wanted && now.saturating_sub(attempted) >= self.min_refetch_seconds
    }

    /// A failed fetch still counts as an attempt and leaves the old keys to age out.
    fn refresh(&self, state: &mut CacheState, now: i64) {
        state.attempted_at = Some(now);
        let parsed = self
            .fetcher
            .fetch()
            .ok()
            .and_then(|body| parse_jwks(&body).ok());
        if let Some(parsed) = parsed {
            state.keys = parsed.keys;
            state.fetched_at = Some(now);
        }
    }
}

impl<F: JwksFetcher> KeySource for JwksCache<F> {
    fn key_for(&self, kid: &str, now: i64) -> Option<VerifyingKey> {
        let mut state = self.lock();
        if self.refresh_due(&state, kid, now) {
            self.refresh(&mut state, now);
        }
        if self.is_stale(&state, now) {
            return None;
        }
        state.keys.get(kid).cloned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::platform_signin::test_support::*;
    use std::collections::VecDeque;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    #[test]
    fn the_thumbprint_of_the_known_answer_key_is_the_documents_kid() {
        assert_eq!(thumbprint(X_A), KID_A);
        assert_eq!(VerifyingKey::from_x(X_A).unwrap().thumbprint(), KID_A);
    }

    #[test]
    fn the_thumbprint_hashes_the_members_in_rfc_7638_order() {
        use sha2::{Digest, Sha256};
        let text = format!(r#"{{"crv":"Ed25519","kty":"OKP","x":"{X_B}"}}"#);
        assert_eq!(
            thumbprint(X_B),
            encode_base64url(&Sha256::digest(text.as_bytes()))
        );
    }

    #[test]
    fn a_key_needs_a_canonical_32_byte_x() {
        assert!(VerifyingKey::from_x(X_A).is_some());
        let short = encode_base64url(&[1u8; 31]);
        let long = encode_base64url(&[1u8; 33]);
        let mut spare_bits = X_A.to_string();
        spare_bits.pop();
        spare_bits.push('l');
        for x in [
            short.as_str(),
            long.as_str(),
            "",
            "!!",
            &format!("{X_A}="),
            spare_bits.as_str(),
        ] {
            assert!(VerifyingKey::from_x(x).is_none(), "{x:?}");
        }
    }

    fn document(entries: &[String]) -> String {
        format!(r#"{{"keys":[{}]}}"#, entries.join(","))
    }

    fn jwk(extra: &str) -> String {
        format!(r#"{{"kty":"OKP","crv":"Ed25519","x":"{X_A}"{extra}}}"#)
    }

    #[test]
    fn a_good_document_is_indexed_by_the_computed_thumbprint() {
        let parsed = parse_jwks(&document(&[jwk(&format!(
            r#","kid":"{KID_A}","alg":"EdDSA","use":"sig""#
        ))]))
        .unwrap();
        assert_eq!(
            parsed.keys.keys().collect::<Vec<_>>(),
            vec![&KID_A.to_string()]
        );
        assert!(parsed.refused.is_empty());
    }

    #[test]
    fn a_claimed_kid_never_names_a_key() {
        let parsed = parse_jwks(&document(&[jwk(r#","kid":"claimed-by-the-document""#)])).unwrap();
        assert!(!parsed.keys.contains_key("claimed-by-the-document"));
        assert_eq!(
            parsed.keys.get(KID_A).map(|k| k.x().to_string()),
            Some(X_A.to_string())
        );
    }

    #[test]
    fn a_document_labelling_one_key_with_anothers_kid_cannot_swap_them() {
        let swapped = format!(r#"{{"kty":"OKP","crv":"Ed25519","x":"{X_B}","kid":"{KID_A}"}}"#);
        let parsed = parse_jwks(&document(&[swapped])).unwrap();
        assert!(!parsed.keys.contains_key(KID_A));
        assert_eq!(parsed.keys.get(&thumbprint(X_B)).unwrap().x(), X_B);
    }

    #[test]
    fn every_entry_that_is_not_a_plain_ed25519_public_key_is_dropped_and_reported() {
        let entries = [
            (
                r#"{"kty":"RSA","n":"AQAB","e":"AQAB"}"#.to_string(),
                KeyRefusal::NotOkp,
            ),
            (
                format!(r#"{{"kty":"EC","crv":"P-256","x":"{X_A}"}}"#),
                KeyRefusal::NotOkp,
            ),
            (
                format!(r#"{{"kty":"OKP","crv":"Ed448","x":"{X_A}"}}"#),
                KeyRefusal::NotEd25519,
            ),
            (
                format!(r#"{{"kty":"OKP","crv":"X25519","x":"{X_A}"}}"#),
                KeyRefusal::NotEd25519,
            ),
            (
                r#"{"kty":"OKP","crv":"Ed25519"}"#.to_string(),
                KeyRefusal::BadX,
            ),
            (
                r#"{"kty":"OKP","crv":"Ed25519","x":"AAAA"}"#.to_string(),
                KeyRefusal::BadX,
            ),
            (
                r#"{"kty":"OKP","crv":"Ed25519","x":7}"#.to_string(),
                KeyRefusal::BadX,
            ),
            (jwk(r#","d":"c2VjcmV0""#), KeyRefusal::CarriesPrivateKey),
            ("[]".to_string(), KeyRefusal::NotAnObject),
            ("\"x\"".to_string(), KeyRefusal::NotAnObject),
        ];
        for (entry, why) in entries {
            let parsed = parse_jwks(&document(std::slice::from_ref(&entry))).unwrap();
            assert!(parsed.keys.is_empty(), "{entry}");
            assert_eq!(parsed.refused, vec![why], "{entry}");
        }
    }

    #[test]
    fn a_private_key_in_the_document_does_not_poison_its_good_neighbours() {
        let parsed = parse_jwks(&document(&[
            jwk(r#","d":"c2VjcmV0""#),
            format!(r#"{{"kty":"OKP","crv":"Ed25519","x":"{X_B}"}}"#),
        ]))
        .unwrap();
        assert_eq!(parsed.keys.len(), 1);
        assert!(parsed.keys.contains_key(&thumbprint(X_B)));
        assert_eq!(parsed.refused, vec![KeyRefusal::CarriesPrivateKey]);
    }

    #[test]
    fn a_document_that_is_not_a_strict_object_with_a_keys_array_is_malformed() {
        let duplicate = format!(r#"{{"keys":[],"keys":[{}]}}"#, jwk(""));
        for body in [
            "",
            "[]",
            "null",
            "{}",
            r#"{"keys":{}}"#,
            r#"{"keys":"x"}"#,
            "not json",
            duplicate.as_str(),
        ] {
            assert_eq!(parse_jwks(body), Err(JwksMalformed), "{body:?}");
        }
        assert!(parse_jwks(r#"{"keys":[]}"#).unwrap().keys.is_empty());
    }

    #[test]
    fn a_repeated_member_inside_a_key_makes_the_document_malformed() {
        let body = document(&[format!(
            r#"{{"kty":"OKP","crv":"Ed25519","x":"{X_A}","x":"{X_B}"}}"#
        )]);
        assert_eq!(parse_jwks(&body), Err(JwksMalformed));
    }

    struct Canned {
        script: Mutex<VecDeque<Result<String, FetchFailed>>>,
        calls: Arc<AtomicUsize>,
    }

    impl JwksFetcher for Canned {
        fn fetch(&self) -> Result<String, FetchFailed> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            let mut script = self.script.lock().unwrap();
            if script.len() > 1 {
                script.pop_front().unwrap()
            } else {
                script.front().cloned().unwrap_or(Err(FetchFailed))
            }
        }
    }

    fn cache_of(script: Vec<Result<String, FetchFailed>>) -> (JwksCache<Canned>, Arc<AtomicUsize>) {
        let calls = Arc::new(AtomicUsize::new(0));
        let fetcher = Canned {
            script: Mutex::new(script.into()),
            calls: calls.clone(),
        };
        (JwksCache::new(fetcher), calls)
    }

    fn one_key(x: &str) -> Result<String, FetchFailed> {
        Ok(document(&[format!(
            r#"{{"kty":"OKP","crv":"Ed25519","x":"{x}"}}"#
        )]))
    }

    #[test]
    fn nothing_is_fetched_until_a_key_is_asked_for_and_a_known_key_is_served_from_memory() {
        let (cache, calls) = cache_of(vec![one_key(X_A)]);
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        assert!(cache.key_for(KID_A, NOW).is_some());
        assert!(cache.key_for(KID_A, NOW + 100).is_some());
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn an_unknown_kid_causes_at_most_one_fetch_per_interval_however_many_arrive() {
        let (cache, calls) = cache_of(vec![one_key(X_A)]);
        assert!(cache.key_for(KID_A, NOW).is_some());
        for i in 0..50 {
            assert!(cache
                .key_for(&format!("unknown-{i}"), NOW + 1 + (i % 28))
                .is_none());
        }
        assert_eq!(
            calls.load(Ordering::SeqCst),
            1,
            "all inside the 30 second interval"
        );
        assert!(cache.key_for("unknown-later", NOW + 30).is_none());
        assert_eq!(calls.load(Ordering::SeqCst), 2);
        assert!(cache.key_for("unknown-again", NOW + 31).is_none());
        assert_eq!(calls.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn a_failed_fetch_counts_as_an_attempt() {
        let (cache, calls) = cache_of(vec![Err(FetchFailed)]);
        for i in 0..20 {
            assert!(cache.key_for(KID_A, NOW + i).is_none());
        }
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert!(cache.key_for(KID_A, NOW + 30).is_none());
        assert_eq!(calls.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn a_failed_refetch_keeps_the_old_keys_until_their_time_to_live_ends() {
        let (cache, calls) = cache_of(vec![one_key(X_A), Err(FetchFailed)]);
        assert!(cache.key_for(KID_A, NOW).is_some());
        assert!(cache.key_for("unknown", NOW + 31).is_none());
        assert_eq!(calls.load(Ordering::SeqCst), 2);
        assert!(
            cache.key_for(KID_A, NOW + 60).is_some(),
            "old key still served"
        );
        assert!(cache.key_for(KID_A, NOW + 299).is_some());
        assert!(
            cache.key_for(KID_A, NOW + 300).is_none(),
            "stale at the time to live, and the refetch failed"
        );
    }

    #[test]
    fn a_stale_cache_refetches_on_the_next_use() {
        let (cache, calls) = cache_of(vec![one_key(X_A)]);
        assert!(cache.key_for(KID_A, NOW).is_some());
        assert!(cache.key_for(KID_A, NOW + 300).is_some());
        assert_eq!(calls.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn rotation_a_previous_key_is_served_while_listed_and_refused_once_removed() {
        let both = document(&[
            format!(r#"{{"kty":"OKP","crv":"Ed25519","x":"{X_A}"}}"#),
            format!(r#"{{"kty":"OKP","crv":"Ed25519","x":"{X_B}"}}"#),
        ]);
        let (cache, _) = cache_of(vec![Ok(both), one_key(X_B)]);
        assert!(cache.key_for(KID_A, NOW).is_some());
        assert!(cache.key_for(&thumbprint(X_B), NOW).is_some());
        assert!(
            cache.key_for(KID_A, NOW + 300).is_none(),
            "refetched document no longer lists it"
        );
        assert!(cache.key_for(&thumbprint(X_B), NOW + 300).is_some());
    }

    #[test]
    fn a_malformed_document_is_a_failed_fetch_and_keeps_the_old_keys() {
        let (cache, _) = cache_of(vec![one_key(X_A), Ok("not json".to_string())]);
        assert!(cache.key_for(KID_A, NOW).is_some());
        assert!(cache.key_for("unknown", NOW + 31).is_none());
        assert!(cache.key_for(KID_A, NOW + 40).is_some());
    }
}
