//! Shared scaffolding for this module's tests: throwaway keys, a signer, and a scenario builder.
//!
//! The seeds are the public throwaway seeds of the known-answer vectors; they are used for nothing
//! else and protect nothing. Tokens are signed with `jsonwebtoken`'s own signer so the tests do not
//! need a second crypto dependency.

use std::collections::HashMap;

use jsonwebtoken::{Algorithm, EncodingKey};
use serde_json::{json, Map, Value};

use super::config::PlatformSigninConfig;
use super::jti::JtiStore;
use super::jwks::{thumbprint, KeySource, VerifyingKey};
use super::jws::encode_base64url;
use super::strict_json::{Json, JsonObject};
use super::verify::{Refusal, SigninCookie, SigninRequest, VerifiedClaims, Verifier};

pub const NOW: i64 = 1_800_000_000;
pub const ISSUER: &str = "https://issuer.example";
pub const SITE: &str = "site-a";
pub const ENVIRONMENT: &str = "production";
pub const EMAIL: &str = "person@example.test";
pub const NONCE: &str = "Nn0nceNn0nceNn0nceAA";
pub const STATE: &str = "StateStateState0123456789";

pub const X_A: &str = "BrQXFhWGK4Fmi8rRsnn1KzomYanZaWCsFWaS0Dgv62k";
pub const KID_A: &str = "SwpkMw_CknhH156gpWgzPJOQNEGnS25LhD1OqeNsQko";
pub const X_B: &str = "y4eb9h3HL-Ojhu6bp87lvE1Nl6b8YjIqM_AGXTRMeB0";
pub const X_C: &str = "VQkfo2GZY1E9zxkI9Sm23OrMYRcXS6PkolH_odg-rS8";

/// A throwaway Ed25519 key pair: its seed and its public `x`.
#[derive(Clone, Copy)]
pub struct TestKey {
    seed: &'static [u8; 32],
    pub x: &'static str,
}

pub const KEY_A: TestKey = TestKey { seed: b"TEST-ONLY-KNOWN-ANSWER-SEED-0001", x: X_A };
pub const KEY_B: TestKey = TestKey { seed: b"TEST-ONLY-KNOWN-ANSWER-SEED-0002", x: X_B };
pub const KEY_C: TestKey = TestKey { seed: b"TEST-ONLY-KNOWN-ANSWER-SEED-0003", x: X_C };

impl TestKey {
    pub fn kid(&self) -> String {
        thumbprint(self.x)
    }

    pub fn verifying(&self) -> VerifyingKey {
        VerifyingKey::from_x(self.x).expect("a valid public key")
    }

    /// Signs `input` as EdDSA and returns the unpadded base64url signature.
    pub fn sign(&self, input: &str) -> String {
        let mut der = vec![0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20];
        der.extend_from_slice(self.seed);
        let key = EncodingKey::from_ed_der(&der);
        jsonwebtoken::crypto::sign(input.as_bytes(), &key, Algorithm::EdDSA).expect("signs")
    }
}

/// Builds `header.claims.signature` from raw JSON texts, signed by `key`.
pub fn assemble(header_text: &str, claims_text: &str, key: &TestKey) -> String {
    let input = format!("{}.{}", encode_base64url(header_text.as_bytes()), encode_base64url(claims_text.as_bytes()));
    format!("{input}.{}", key.sign(&input))
}

/// A key source that holds a fixed set of keys, by computed thumbprint.
pub struct StaticKeys(pub HashMap<String, VerifyingKey>);

impl KeySource for StaticKeys {
    fn key_for(&self, kid: &str, _now: i64) -> Option<VerifyingKey> {
        self.0.get(kid).cloned()
    }
}

pub fn static_keys(keys: &[&TestKey]) -> StaticKeys {
    StaticKeys(keys.iter().map(|k| (k.kid(), k.verifying())).collect())
}

pub fn config() -> PlatformSigninConfig {
    PlatformSigninConfig::new(ISSUER, "https://issuer.example/.well-known/jwks.json", SITE, ENVIRONMENT)
}

pub fn verifier_for(keys: &[&TestKey]) -> Verifier<StaticKeys> {
    Verifier::new(config(), static_keys(keys), JtiStore::new())
}

pub fn good_cookie() -> SigninCookie {
    SigninCookie { nonce: NONCE.into(), state: STATE.into() }
}

/// Turns a verified or raw claim object into a `serde_json::Value`, for comparisons.
pub fn to_value(json: &Json) -> Value {
    match json {
        Json::Null => Value::Null,
        Json::Bool(b) => Value::Bool(*b),
        Json::Int(i) => Value::from(i64::try_from(*i).unwrap_or(i64::MAX)),
        Json::Number => Value::from(0.5),
        Json::Str(s) => Value::String(s.clone()),
        Json::Array(items) => Value::Array(items.iter().map(to_value).collect()),
        Json::Object(object) => object_to_value(object),
    }
}

pub fn object_to_value(object: &JsonObject) -> Value {
    Value::Object(object.keys().map(|k| (k.clone(), to_value(object.get(k).expect("member")))).collect())
}

/// One sign-in attempt, built from a good one by mutating the pieces a test wants to break.
pub struct Scenario {
    pub header: Map<String, Value>,
    pub claims: Map<String, Value>,
    pub signer: TestKey,
    pub state: Option<String>,
    pub cookie: Option<SigninCookie>,
    pub flip_signature: bool,
    pub replace_token: Option<String>,
    pub spend_first: bool,
    pub now: i64,
}

impl Scenario {
    pub fn good() -> Self {
        let claims = json!({
            "iss": ISSUER, "aud": SITE, "env": ENVIRONMENT, "sub": EMAIL,
            "idp_iss": "https://idp.example", "idp_sub": "idp-subject-0001",
            "email": EMAIL, "email_verified": true, "roles": ["Admin"], "nonce": NONCE,
            "iat": NOW, "nbf": NOW, "exp": NOW + 60, "jti": "jti-scenario-0000000000"
        });
        let header = json!({"alg": "EdDSA", "typ": "JWT", "kid": KEY_A.kid()});
        Self {
            header: header.as_object().cloned().unwrap(),
            claims: claims.as_object().cloned().unwrap(),
            signer: KEY_A,
            state: Some(STATE.into()),
            cookie: Some(good_cookie()),
            flip_signature: false,
            replace_token: None,
            spend_first: false,
            now: NOW,
        }
    }

    /// Builds the token text, signed over the (possibly mutated) header and claims.
    pub fn token(&self) -> String {
        if let Some(text) = &self.replace_token {
            return text.clone();
        }
        let header = Value::Object(self.header.clone()).to_string();
        let claims = Value::Object(self.claims.clone()).to_string();
        let token = assemble(&header, &claims, &self.signer);
        if self.flip_signature { flip_last_signature_bit(&token) } else { token }
    }

    /// Runs the scenario through `verifier`, spending the jti first when asked.
    pub fn run(&self, verifier: &Verifier<StaticKeys>) -> Result<VerifiedClaims, Refusal> {
        if self.spend_first {
            let jti = self.claims.get("jti").and_then(Value::as_str).expect("a jti to spend");
            assert!(verifier.jti_store().claim(jti, self.now + 90, self.now));
        }
        let token = self.token();
        let request = SigninRequest { token: Some(&token), state: self.state.as_deref(), cookie: self.cookie.as_ref() };
        verifier.verify(&request, self.now)
    }
}

/// Changes the first bit of the signature's first byte, keeping the segment canonical.
pub fn flip_last_signature_bit(token: &str) -> String {
    let (input, signature) = token.rsplit_once('.').expect("three segments");
    let mut bytes = super::jws::decode_base64url(signature).expect("canonical signature");
    bytes[0] ^= 1;
    format!("{input}.{}", encode_base64url(&bytes))
}

/// A key-set fetcher backed by a closure, for cache tests.
pub struct FnFetcher(pub Box<dyn Fn() -> Result<String, super::jwks::FetchFailed> + Send + Sync>);

impl super::jwks::JwksFetcher for FnFetcher {
    fn fetch(&self) -> Result<String, super::jwks::FetchFailed> {
        (self.0)()
    }
}

/// A key set document listing `keys`.
pub fn jwks_document(keys: &[&TestKey]) -> String {
    let entries: Vec<String> = keys.iter().map(|k| format!(r#"{{"kty":"OKP","crv":"Ed25519","x":"{}"}}"#, k.x)).collect();
    format!(r#"{{"keys":[{}]}}"#, entries.join(","))
}
