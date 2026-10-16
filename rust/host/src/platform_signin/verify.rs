//! The ordered checks that decide whether a platform sign-in token may be used.
//!
//! ## The order is the contract
//!
//! The checks run in a fixed order and the first failure is the verdict: the site's cookie, then the
//! state, the size, the structure, the header, the key and signature, the claims, the nonce, the
//! single-use identifier, and last the identity. Three consequences matter:
//!
//! - A request that fails early learns nothing about later checks (a forged request with a bad state
//!   is not told whether its token was expired).
//! - The `jti` is spent only after every check before it passed, so an attacker who replays a
//!   victim's token with the wrong nonce cannot burn it.
//! - Every refusal is one of the stable [`Reason`] codes, the same ones, in the same order, as the
//!   issuer's reference verifier.
//!
//! ## What the caller supplies
//!
//! The query `token` and `state`, the pair of values from the site's own sign-in cookie, and the
//! time. State and nonce are compared through an injected comparison so a test can see that it is
//! the one in use; the default hashes both sides and compares fixed-length digests.

use super::config::PlatformSigninConfig;
use super::jti::JtiStore;
use super::jwks::KeySource;
use super::strict_json::JsonObject;

/// Why a token was refused; the stable code is the contract with the issuer's reference verifier.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Reason {
    MissingCookie,
    StateMismatch,
    TooLarge,
    Malformed,
    BadAlg,
    UnknownKid,
    BadSignature,
    BadIss,
    BadAud,
    BadEnv,
    MissingClaim,
    NotYetValid,
    Expired,
    Lifetime,
    NonceMismatch,
    Replay,
    EmailUnverified,
    SubjectMismatch,
}

impl Reason {
    /// Every reason, in the order the checks run.
    pub const ALL: [Reason; 18] = [
        Reason::MissingCookie,
        Reason::StateMismatch,
        Reason::TooLarge,
        Reason::Malformed,
        Reason::BadAlg,
        Reason::UnknownKid,
        Reason::BadSignature,
        Reason::BadIss,
        Reason::BadAud,
        Reason::BadEnv,
        Reason::MissingClaim,
        Reason::NotYetValid,
        Reason::Expired,
        Reason::Lifetime,
        Reason::NonceMismatch,
        Reason::Replay,
        Reason::EmailUnverified,
        Reason::SubjectMismatch,
    ];

    /// Returns the stable lowercase code, such as `"bad_aud"`.
    pub fn code(self) -> &'static str {
        todo!("Reason::code")
    }

    /// Finds the reason that has this code.
    pub fn from_code(code: &str) -> Option<Reason> {
        let _ = code;
        todo!("Reason::from_code")
    }
}

/// A refused token, carrying the stable reason and nothing of the token.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Refusal {
    pub reason: Reason,
}

impl Refusal {
    /// Returns the stable reason code.
    pub fn code(&self) -> &'static str {
        self.reason.code()
    }
}

/// The two values the site stored in the browser when it started the sign-in.
///
/// An empty value counts as absent: a cookie missing either one is a cookie that was never set.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SigninCookie {
    pub nonce: String,
    pub state: String,
}

/// What arrived on the callback and what the browser's cookie held.
#[derive(Clone, Copy)]
pub struct SigninRequest<'a> {
    /// The `token` query parameter, `None` when absent.
    pub token: Option<&'a str>,
    /// The `state` query parameter, `None` when absent.
    pub state: Option<&'a str>,
    /// The parsed sign-in cookie, `None` when the browser sent none.
    pub cookie: Option<&'a SigninCookie>,
}

/// The claims of a token that passed every check.
#[derive(Debug, Clone, PartialEq)]
pub struct VerifiedClaims {
    pub issuer: String,
    pub audience: String,
    pub environment: String,
    pub subject: String,
    /// The email, lowercased.
    pub email: String,
    pub idp_issuer: Option<String>,
    pub idp_subject: Option<String>,
    /// The `roles` claim when it is an array; its string members only.
    pub roles: Vec<String>,
    pub nonce: String,
    pub jti: String,
    pub issued_at: i64,
    pub not_before: i64,
    pub expires_at: i64,
    /// Every claim as signed.
    pub all: JsonObject,
}

/// A comparison of two secrets for equality, injected so tests can observe its use.
pub type SecureCompare = Box<dyn Fn(&str, &str) -> bool + Send + Sync>;

/// Compares two strings without the timing depending on where they first differ or on their lengths.
///
/// Both sides are hashed first so the comparison runs over equal-length digests.
pub fn secure_compare(a: &str, b: &str) -> bool {
    let _ = (a, b);
    todo!("secure_compare")
}

/// Runs the ordered checks against one issuer, site and environment.
pub struct Verifier<K: KeySource> {
    config: PlatformSigninConfig,
    keys: K,
    jti_store: JtiStore,
    compare: SecureCompare,
}

impl<K: KeySource> Verifier<K> {
    /// Builds a verifier that uses [`secure_compare`] for state and nonce.
    pub fn new(config: PlatformSigninConfig, keys: K, jti_store: JtiStore) -> Self {
        Self { config, keys, jti_store, compare: Box::new(secure_compare) }
    }

    /// Replaces the comparison used for state and nonce.
    pub fn with_compare(mut self, compare: SecureCompare) -> Self {
        self.compare = compare;
        self
    }

    /// Exposes the single-use record, so a caller can share or inspect it.
    pub fn jti_store(&self) -> &JtiStore {
        &self.jti_store
    }

    /// Decides whether a token may be used at `now` (Unix seconds).
    ///
    /// # Errors
    ///
    /// Returns the [`Refusal`] of the first check that fails, in the order the module documents.
    /// Never panics on hostile input.
    pub fn verify(&self, request: &SigninRequest<'_>, now: i64) -> Result<VerifiedClaims, Refusal> {
        let _ = (request, now, &self.config, &self.keys, &self.compare);
        todo!("Verifier::verify")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::platform_signin::test_support::*;
    use std::sync::{Arc, Mutex};

    const DOCUMENTED_ORDER: &str = "missing_cookie, state_mismatch, too_large, malformed, bad_alg, unknown_kid, bad_signature, \
         bad_iss, bad_aud, bad_env, missing_claim, not_yet_valid, expired, lifetime, nonce_mismatch, replay, \
         email_unverified, subject_mismatch";

    #[test]
    fn the_reason_codes_are_the_issuers_codes_in_the_issuers_order() {
        let codes: Vec<&str> = Reason::ALL.iter().map(|r| r.code()).collect();
        assert_eq!(codes.join(", "), DOCUMENTED_ORDER);
    }

    #[test]
    fn a_code_maps_back_to_its_reason_and_nothing_else_does() {
        for reason in Reason::ALL {
            assert_eq!(Reason::from_code(reason.code()), Some(reason));
        }
        for text in ["", "BadAud", "bad_aud ", "accept", "refuse", "unknown"] {
            assert_eq!(Reason::from_code(text), None, "{text:?}");
        }
        assert_eq!(Refusal { reason: Reason::Replay }.code(), "replay");
    }

    #[test]
    fn secure_compare_is_plain_equality_for_equal_different_and_different_length_input() {
        assert!(secure_compare("", ""));
        assert!(secure_compare("abc", "abc"));
        assert!(!secure_compare("abc", "abd"));
        assert!(!secure_compare("abc", "ab"));
        assert!(!secure_compare("ab", "abc"));
        assert!(!secure_compare("", "a"));
        assert!(!secure_compare("\u{e9}", "e"));
    }

    fn spy() -> (SecureCompare, Arc<Mutex<Vec<(String, String)>>>) {
        let calls = Arc::new(Mutex::new(Vec::new()));
        let seen = calls.clone();
        let compare: SecureCompare = Box::new(move |a, b| {
            seen.lock().unwrap().push((a.to_string(), b.to_string()));
            a == b
        });
        (compare, calls)
    }

    #[test]
    fn state_and_nonce_are_compared_through_the_injected_seam() {
        let (compare, calls) = spy();
        let verifier = verifier_for(&[&KEY_A]).with_compare(compare);
        let scenario = Scenario::good();
        assert!(scenario.run(&verifier).is_ok());
        let calls = calls.lock().unwrap();
        assert!(calls.contains(&(STATE.to_string(), STATE.to_string())), "state goes through the seam: {calls:?}");
        assert!(calls.contains(&(NONCE.to_string(), NONCE.to_string())), "nonce goes through the seam: {calls:?}");
    }

    #[test]
    fn a_seam_that_says_no_refuses_even_equal_state_and_equal_nonce() {
        let state_refused = verifier_for(&[&KEY_A]).with_compare(Box::new(|a, _| a != STATE));
        assert_eq!(Scenario::good().run(&state_refused).unwrap_err().reason, Reason::StateMismatch);
        let nonce_refused = verifier_for(&[&KEY_A]).with_compare(Box::new(|a, _| a != NONCE));
        assert_eq!(Scenario::good().run(&nonce_refused).unwrap_err().reason, Reason::NonceMismatch);
    }

    #[test]
    fn a_seam_that_says_yes_accepts_a_different_state_and_a_different_nonce() {
        let verifier = verifier_for(&[&KEY_A]).with_compare(Box::new(|_, _| true));
        let mut scenario = Scenario::good();
        scenario.state = Some("not-the-cookies-state".into());
        scenario.claims.insert("nonce".into(), "not-the-cookies-nonce".into());
        assert!(scenario.run(&verifier).is_ok(), "the verdict is the seam's, nothing else compares them");
    }

    #[test]
    fn the_seam_is_not_consulted_for_a_nonce_before_the_earlier_checks_pass() {
        let (compare, calls) = spy();
        let verifier = verifier_for(&[&KEY_A]).with_compare(compare);
        let mut scenario = Scenario::good();
        scenario.flip_signature = true;
        assert_eq!(scenario.run(&verifier).unwrap_err().reason, Reason::BadSignature);
        assert!(calls.lock().unwrap().iter().all(|(a, _)| a == STATE), "only the state was compared");
    }

    #[test]
    fn a_good_token_yields_typed_claims_with_the_email_lowercased() {
        let verifier = verifier_for(&[&KEY_A]);
        let mut scenario = Scenario::good();
        scenario.claims.insert("email".into(), "Person@Example.Test".into());
        let claims = scenario.run(&verifier).expect("accepted");
        assert_eq!(claims.email, "person@example.test");
        assert_eq!(claims.subject, "person@example.test");
        assert_eq!((claims.issuer.as_str(), claims.audience.as_str(), claims.environment.as_str()), (ISSUER, SITE, ENVIRONMENT));
        assert_eq!(claims.roles, vec!["Admin".to_string()]);
        assert_eq!(claims.idp_issuer.as_deref(), Some("https://idp.example"));
        assert_eq!(claims.idp_subject.as_deref(), Some("idp-subject-0001"));
        assert_eq!((claims.issued_at, claims.not_before, claims.expires_at), (NOW, NOW, NOW + 60));
        assert_eq!(claims.nonce, NONCE);
        assert_eq!(claims.all.get_str("email"), Some("Person@Example.Test"));
    }

    #[test]
    fn a_refusal_and_its_debug_text_never_hold_the_token() {
        let verifier = verifier_for(&[&KEY_A]);
        let mut scenario = Scenario::good();
        scenario.flip_signature = true;
        let token = scenario.token();
        let refusal = scenario.run(&verifier).unwrap_err();
        assert!(!format!("{refusal:?} {refusal:#?}").contains(&token[..20]));
    }
}
