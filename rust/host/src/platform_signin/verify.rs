//! The ordered checks that decide whether a platform sign-in token may be used.
//!
//! ## The order is the contract
//!
//! The checks run in a fixed order and the first failure is the verdict: the site's cookie, then
//! the
//! state, the size, the structure, the header, the key and signature, the claims, the nonce, the
//! single-use identifier, and last the identity. Three consequences matter:
//!
//! - A request that fails early learns nothing about later checks (a forged request with a bad
//! state
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

use jsonwebtoken::{Algorithm, DecodingKey};
use sha2::{Digest, Sha256};

use super::config::PlatformSigninConfig;
use super::jti::JtiStore;
use super::jwks::{KeySource, VerifyingKey};
use super::jws::{CompactJws, JwsFault};
use super::strict_json::{Json, JsonObject};

/// The only signature algorithm accepted, compared exactly.
const ALGORITHM: &str = "EdDSA";
/// The only token type accepted, compared exactly.
const TOKEN_TYPE: &str = "JWT";
/// The claims every token must carry, present and not `null`.
const REQUIRED_CLAIMS: [&str; 11] = [
    "iss",
    "aud",
    "env",
    "sub",
    "email",
    "email_verified",
    "nonce",
    "iat",
    "nbf",
    "exp",
    "jti",
];

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
    pub const ALL: [Self; 18] = [
        Self::MissingCookie,
        Self::StateMismatch,
        Self::TooLarge,
        Self::Malformed,
        Self::BadAlg,
        Self::UnknownKid,
        Self::BadSignature,
        Self::BadIss,
        Self::BadAud,
        Self::BadEnv,
        Self::MissingClaim,
        Self::NotYetValid,
        Self::Expired,
        Self::Lifetime,
        Self::NonceMismatch,
        Self::Replay,
        Self::EmailUnverified,
        Self::SubjectMismatch,
    ];

    /// Returns the stable lowercase code, such as `"bad_aud"`.
    pub const fn code(self) -> &'static str {
        match self {
            Self::MissingCookie => "missing_cookie",
            Self::StateMismatch => "state_mismatch",
            Self::TooLarge => "too_large",
            Self::Malformed => "malformed",
            Self::BadAlg => "bad_alg",
            Self::UnknownKid => "unknown_kid",
            Self::BadSignature => "bad_signature",
            Self::BadIss => "bad_iss",
            Self::BadAud => "bad_aud",
            Self::BadEnv => "bad_env",
            Self::MissingClaim => "missing_claim",
            Self::NotYetValid => "not_yet_valid",
            Self::Expired => "expired",
            Self::Lifetime => "lifetime",
            Self::NonceMismatch => "nonce_mismatch",
            Self::Replay => "replay",
            Self::EmailUnverified => "email_unverified",
            Self::SubjectMismatch => "subject_mismatch",
        }
    }

    /// Finds the reason that has this code.
    pub fn from_code(code: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|reason| reason.code() == code)
    }
}

/// A refused token, carrying the stable reason and nothing of the token.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Refusal {
    pub reason: Reason,
}

impl Refusal {
    /// Returns the stable reason code.
    pub const fn code(&self) -> &'static str {
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
    pub issued_at: i64,
    pub not_before: i64,
    pub expires_at: i64,
    /// Every claim as signed.
    pub all: JsonObject,
}

/// A comparison of two secrets for equality, injected so tests can observe its use.
pub type SecureCompare = Box<dyn Fn(&str, &str) -> bool + Send + Sync>;

/// Compares two strings without the timing depending on where they first differ or on their
/// lengths.
///
/// Both sides are hashed first so the comparison runs over equal-length digests.
pub fn secure_compare(a: &str, b: &str) -> bool {
    let (left, right) = (Sha256::digest(a.as_bytes()), Sha256::digest(b.as_bytes()));
    left.iter()
        .zip(right.iter())
        .fold(0u8, |difference, (x, y)| difference | (x ^ y))
        == 0
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
        Self {
            config,
            keys,
            jti_store,
            compare: Box::new(secure_compare),
        }
    }

    /// Replaces the comparison used for state and nonce.
    pub fn with_compare(mut self, compare: SecureCompare) -> Self {
        self.compare = compare;
        self
    }

    /// Exposes the single-use record, so a caller can share or inspect it.
    pub const fn jti_store(&self) -> &JtiStore {
        &self.jti_store
    }

    /// Decides whether a token may be used at `now` (Unix seconds).
    ///
    /// # Errors
    ///
    /// Returns the [`Refusal`] of the first check that fails, in the order the module documents.
    /// Never panics on hostile input.
    pub fn verify(&self, request: &SigninRequest<'_>, now: i64) -> Result<VerifiedClaims, Refusal> {
        self.run_checks(request, now)
            .map_err(|reason| Refusal { reason })
    }

    fn run_checks(&self, request: &SigninRequest<'_>, now: i64) -> Result<VerifiedClaims, Reason> {
        let cookie = self.check_cookie_and_state(request)?;
        let jws = parse_token(request.token, self.config.max_token_bytes)?;
        self.check_signature(&jws, now)?;
        let claims = &jws.claims;
        self.check_pinned_claims(claims)?;
        self.check_times(claims, now)?;
        self.check_nonce(claims, cookie)?;
        self.spend_jti(claims, now)?;
        check_identity(claims)?;
        Ok(accepted(jws.claims))
    }

    /// The site's own cookie must be present, and its state must equal the query's.
    fn check_cookie_and_state<'r>(
        &self,
        request: &SigninRequest<'r>,
    ) -> Result<&'r SigninCookie, Reason> {
        let cookie = request
            .cookie
            .filter(|c| !c.nonce.is_empty() && !c.state.is_empty())
            .ok_or(Reason::MissingCookie)?;
        let state = request
            .state
            .filter(|s| !s.is_empty())
            .ok_or(Reason::StateMismatch)?;
        if (self.compare)(state, &cookie.state) {
            Ok(cookie)
        } else {
            Err(Reason::StateMismatch)
        }
    }

    /// The algorithm is pinned before any key is looked up, so a header can never choose its own
    /// check.
    fn check_signature(&self, jws: &CompactJws, now: i64) -> Result<(), Reason> {
        if jws.header.get_str("alg") != Some(ALGORITHM) {
            return Err(Reason::BadAlg);
        }
        if jws.header.get_str("typ") != Some(TOKEN_TYPE) {
            return Err(Reason::Malformed);
        }
        jws.signature_bytes().ok_or(Reason::Malformed)?;
        let key = jws
            .header
            .get_str("kid")
            .and_then(|kid| self.keys.key_for(kid, now))
            .ok_or(Reason::UnknownKid)?;
        if signature_verifies(&key, jws) {
            Ok(())
        } else {
            Err(Reason::BadSignature)
        }
    }

    /// Presence, then the exact issuer, site and environment, in that order.
    fn check_pinned_claims(&self, claims: &JsonObject) -> Result<(), Reason> {
        if REQUIRED_CLAIMS.iter().any(|name| !claims.is_present(name)) {
            return Err(Reason::MissingClaim);
        }
        if claims.get_str("iss") != Some(self.config.issuer_url.as_str()) {
            return Err(Reason::BadIss);
        }
        if claims.get_str("aud") != Some(self.config.site_id.as_str()) {
            return Err(Reason::BadAud);
        }
        if claims.get_str("env") != Some(self.config.environment.as_str()) {
            return Err(Reason::BadEnv);
        }
        Ok(())
    }

    /// Integer times only, then not-yet-valid, expired and lifetime, in that order.
    fn check_times(&self, claims: &JsonObject, now: i64) -> Result<(), Reason> {
        let (iat, nbf, exp) = (
            integer(claims, "iat"),
            integer(claims, "nbf"),
            integer(claims, "exp"),
        );
        let (Some(iat), Some(nbf), Some(exp)) = (iat, nbf, exp) else {
            return Err(Reason::Malformed);
        };
        let (now, skew) = (i128::from(now), i128::from(self.config.skew_seconds));
        if nbf > now.saturating_add(skew) {
            return Err(Reason::NotYetValid);
        }
        if exp <= now.saturating_sub(skew) {
            return Err(Reason::Expired);
        }
        let lifetime = exp.saturating_sub(iat);
        if (1..=i128::from(self.config.max_lifetime_seconds)).contains(&lifetime) {
            Ok(())
        } else {
            Err(Reason::Lifetime)
        }
    }

    fn check_nonce(&self, claims: &JsonObject, cookie: &SigninCookie) -> Result<(), Reason> {
        match claims.get_str("nonce") {
            Some(nonce) if (self.compare)(nonce, &cookie.nonce) => Ok(()),
            _ => Err(Reason::NonceMismatch),
        }
    }

    /// Spends the `jti`. Called only after every check before it passed, so a request that fails
    /// earlier can never burn a token that belongs to someone else.
    fn spend_jti(&self, claims: &JsonObject, now: i64) -> Result<(), Reason> {
        let jti = claims
            .get_str("jti")
            .filter(|jti| !jti.is_empty())
            .ok_or(Reason::Replay)?;
        let remembered_until = clamp(
            integer(claims, "exp")
                .unwrap_or(0)
                .saturating_add(i128::from(self.config.skew_seconds)),
        );
        if self.jti_store.claim(jti, remembered_until, now) {
            Ok(())
        } else {
            Err(Reason::Replay)
        }
    }
}

fn parse_token(token: Option<&str>, max_bytes: usize) -> Result<CompactJws, Reason> {
    let token = token.ok_or(Reason::Malformed)?;
    CompactJws::parse(token, max_bytes).map_err(|fault| match fault {
        JwsFault::TooLarge => Reason::TooLarge,
        JwsFault::Malformed => Reason::Malformed,
    })
}

fn signature_verifies(key: &VerifyingKey, jws: &CompactJws) -> bool {
    let Ok(decoding_key) = DecodingKey::from_ed_components(key.x()) else {
        return false;
    };
    jsonwebtoken::crypto::verify(
        &jws.signature_segment,
        jws.signing_input.as_bytes(),
        &decoding_key,
        Algorithm::EdDSA,
    )
    .unwrap_or(false)
}

fn integer(claims: &JsonObject, name: &str) -> Option<i128> {
    match claims.get(name) {
        Some(Json::Int(value)) => Some(*value),
        _ => None,
    }
}

fn clamp(value: i128) -> i64 {
    i64::try_from(value).unwrap_or(if value < 0 { i64::MIN } else { i64::MAX })
}

/// A verified token must say the provider verified the email, and `sub` must be that email
/// lowercased.
fn check_identity(claims: &JsonObject) -> Result<(), Reason> {
    if claims.get("email_verified") != Some(&Json::Bool(true)) {
        return Err(Reason::EmailUnverified);
    }
    let (Some(email), Some(subject)) = (claims.get_str("email"), claims.get_str("sub")) else {
        return Err(Reason::Malformed);
    };
    if subject == email.to_lowercase() {
        Ok(())
    } else {
        Err(Reason::SubjectMismatch)
    }
}

fn accepted(all: JsonObject) -> VerifiedClaims {
    let text = |name: &str| all.get_str(name).unwrap_or_default().to_string();
    let optional = |name: &str| all.get_str(name).map(str::to_string);
    let time = |name: &str| clamp(integer(&all, name).unwrap_or(0));
    VerifiedClaims {
        issuer: text("iss"),
        audience: text("aud"),
        environment: text("env"),
        subject: text("sub"),
        email: text("email").to_lowercase(),
        idp_issuer: optional("idp_iss"),
        idp_subject: optional("idp_sub"),
        roles: role_names(&all),
        nonce: text("nonce"),
        issued_at: time("iat"),
        not_before: time("nbf"),
        expires_at: time("exp"),
        all,
    }
}

fn role_names(claims: &JsonObject) -> Vec<String> {
    match claims.get("roles") {
        Some(Json::Array(items)) => items
            .iter()
            .filter_map(|item| {
                if let Json::Str(role) = item {
                    Some(role.clone())
                } else {
                    None
                }
            })
            .collect(),
        _ => Vec::new(),
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
        assert_eq!(
            Refusal {
                reason: Reason::Replay
            }
            .code(),
            "replay"
        );
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

    type Calls = Arc<Mutex<Vec<(String, String)>>>;

    fn spy() -> (SecureCompare, Calls) {
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
        assert!(
            calls.contains(&(STATE.to_string(), STATE.to_string())),
            "state goes through the seam: {calls:?}"
        );
        assert!(
            calls.contains(&(NONCE.to_string(), NONCE.to_string())),
            "nonce goes through the seam: {calls:?}"
        );
    }

    #[test]
    fn a_seam_that_says_no_refuses_even_equal_state_and_equal_nonce() {
        let state_refused = verifier_for(&[&KEY_A]).with_compare(Box::new(|a, _| a != STATE));
        assert_eq!(
            Scenario::good().run(&state_refused).unwrap_err().reason,
            Reason::StateMismatch
        );
        let nonce_refused = verifier_for(&[&KEY_A]).with_compare(Box::new(|a, _| a != NONCE));
        assert_eq!(
            Scenario::good().run(&nonce_refused).unwrap_err().reason,
            Reason::NonceMismatch
        );
    }

    #[test]
    fn a_seam_that_says_yes_accepts_a_different_state_and_a_different_nonce() {
        let verifier = verifier_for(&[&KEY_A]).with_compare(Box::new(|_, _| true));
        let mut scenario = Scenario::good();
        scenario.state = Some("not-the-cookies-state".into());
        scenario
            .claims
            .insert("nonce".into(), "not-the-cookies-nonce".into());
        assert!(
            scenario.run(&verifier).is_ok(),
            "the verdict is the seam's, nothing else compares them"
        );
    }

    #[test]
    fn the_seam_is_not_consulted_for_a_nonce_before_the_earlier_checks_pass() {
        let (compare, calls) = spy();
        let verifier = verifier_for(&[&KEY_A]).with_compare(compare);
        let mut scenario = Scenario::good();
        scenario.flip_signature = true;
        assert_eq!(
            scenario.run(&verifier).unwrap_err().reason,
            Reason::BadSignature
        );
        assert!(
            calls.lock().unwrap().iter().all(|(a, _)| a == STATE),
            "only the state was compared"
        );
    }

    #[test]
    fn a_good_token_yields_typed_claims_with_the_email_lowercased() {
        let verifier = verifier_for(&[&KEY_A]);
        let mut scenario = Scenario::good();
        scenario
            .claims
            .insert("email".into(), "Person@Example.Test".into());
        let claims = scenario.run(&verifier).expect("accepted");
        assert_eq!(claims.email, "person@example.test");
        assert_eq!(claims.subject, "person@example.test");
        assert_eq!(
            (
                claims.issuer.as_str(),
                claims.audience.as_str(),
                claims.environment.as_str()
            ),
            (ISSUER, SITE, ENVIRONMENT)
        );
        assert_eq!(claims.roles, vec!["Admin".to_string()]);
        assert_eq!(claims.idp_issuer.as_deref(), Some("https://idp.example"));
        assert_eq!(claims.idp_subject.as_deref(), Some("idp-subject-0001"));
        assert_eq!(
            (claims.issued_at, claims.not_before, claims.expires_at),
            (NOW, NOW, NOW + 60)
        );
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
