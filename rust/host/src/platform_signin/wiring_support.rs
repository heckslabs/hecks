//! Shared scaffolding for the wiring tests: settings, a recording log, a fake member directory,
//! and the known-answer vectors turned into callback requests.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use serde_json::{json, Value};

use super::config::PlatformSigninConfig;
use super::handler::{CallbackRequest, Random, SigninHandler, SigninLog};
use super::jti::JtiStore;
use super::jwks::parse_jwks;
use super::session::MemberDirectory;
use super::settings::SigninSettings;
use super::test_support::StaticKeys;
use super::verify::Verifier;
use crate::auth::Session;

pub const SITE_URL: &str = "https://site.example";
pub const SECRET: &str = "a-long-session-secret-for-tests";
pub const ISSUER: &str = "https://issuer.example";
pub const NONCE_A: &str = "NonceNonceNonce0123456789abcdefghijklmn";
pub const STATE_A: &str = "StateStateState0123456789abcdefghijklmn";
pub const NONCE_B: &str = "NonceBNonceBNonceB0123456789abcdefghijk";
pub const STATE_B: &str = "StateBStateBStateB0123456789abcdefghijk";

/// The environment map a site with `mode` switched on would have.
pub fn env_map(mode: &str) -> HashMap<String, String> {
    [
        ("PLATFORM_SIGNIN", mode),
        ("PLATFORM_ISSUER_URL", ISSUER),
        ("PLATFORM_SITE_ID", "site-a"),
        ("PLATFORM_ENVIRONMENT", "production"),
        ("SITE_URL", SITE_URL),
        ("SESSION_SECRET", SECRET),
        ("HECKS_SERVE_MODE", "1"),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), v.to_string()))
    .collect()
}

/// Validated settings for `mode`.
pub fn settings(mode: &str) -> SigninSettings {
    SigninSettings::from_env_map(&env_map(mode))
        .expect("valid")
        .expect("switched on")
}

/// A log that keeps every event.
#[derive(Default)]
pub struct Recorder(Mutex<Vec<(String, Value)>>);

impl SigninLog for Recorder {
    fn record(&self, event: &str, fields: Value) {
        self.0.lock().unwrap().push((event.to_string(), fields));
    }
}

impl Recorder {
    /// Every recorded event as one text, for searching.
    pub fn text(&self) -> String {
        self.0
            .lock()
            .unwrap()
            .iter()
            .map(|(e, f)| format!("{e} {f}"))
            .collect::<Vec<_>>()
            .join("\n")
    }

    /// The names of the recorded events, in order.
    pub fn events(&self) -> Vec<String> {
        self.0
            .lock()
            .unwrap()
            .iter()
            .map(|(e, _)| e.clone())
            .collect()
    }

    /// The fields of the first event called `name`.
    pub fn fields_of(&self, name: &str) -> Option<Value> {
        self.0
            .lock()
            .unwrap()
            .iter()
            .find(|(e, _)| e == name)
            .map(|(_, f)| f.clone())
    }
}

/// A person the fake store knows.
#[derive(Clone)]
pub struct Person {
    pub email: String,
    pub role: Option<String>,
}

impl Person {
    /// Builds a person with this email and local role.
    pub fn new(email: &str, role: Option<&str>) -> Self {
        Self {
            email: email.into(),
            role: role.map(str::to_string),
        }
    }

    fn session(&self) -> Session {
        Session {
            identity_id: "identity-1".into(),
            email: self.email.clone(),
            name: "Person".into(),
            role: self.role.clone(),
        }
    }
}

/// A member store with scripted answers that remembers what it was asked.
#[derive(Default)]
pub struct FakeMembers {
    /// `(issuer, subject)` -> identity id.
    pub identities: HashMap<(String, String), String>,
    /// identity id -> the linked member.
    pub linked: HashMap<String, Person>,
    /// What linking by email answers.
    pub provisions: Option<Person>,
    pub fail: bool,
    pub calls: Mutex<Vec<String>>,
}

impl FakeMembers {
    /// A store where the vectors' identity resolves to `person`.
    pub fn resolving(person: Person) -> Self {
        let mut store = Self::default();
        store.identities.insert(
            ("https://idp.example".into(), "idp-subject-0001".into()),
            "identity-1".into(),
        );
        store.linked.insert("identity-1".into(), person);
        store
    }

    /// A store where nothing resolves and linking by email yields `person`.
    pub fn provisioning(person: Person) -> Self {
        Self {
            provisions: Some(person),
            ..Self::default()
        }
    }

    /// Lists the calls made so far, in order.
    pub fn called(&self) -> Vec<String> {
        self.calls.lock().unwrap().clone()
    }

    fn note(&self, call: &str) -> anyhow::Result<()> {
        self.calls.lock().unwrap().push(call.to_string());
        if self.fail {
            anyhow::bail!("the store is down");
        }
        Ok(())
    }
}

#[async_trait]
impl MemberDirectory for FakeMembers {
    async fn identity_for(&self, issuer: &str, subject: &str) -> anyhow::Result<Option<String>> {
        self.note("identity_for")?;
        Ok(self
            .identities
            .get(&(issuer.to_string(), subject.to_string()))
            .cloned())
    }

    async fn session_for_identity(&self, identity_id: &str) -> anyhow::Result<Option<Session>> {
        self.note("session_for_identity")?;
        Ok(self.linked.get(identity_id).map(Person::session))
    }

    async fn provision(
        &self,
        email: &str,
        issuer: &str,
        subject: &str,
    ) -> anyhow::Result<Option<Session>> {
        self.note(&format!("provision {email} {issuer} {subject}"))?;
        Ok(self.provisions.as_ref().map(Person::session))
    }
}

/// The known-answer file.
pub fn vectors() -> Value {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/fixtures/platform_signin_vectors.json"
    );
    serde_json::from_slice(&std::fs::read(path).expect("vectors")).expect("json")
}

/// A verifier that trusts the vectors' key set and pins its issuer, site and environment.
pub fn vector_verifier(doc: &Value) -> Verifier<StaticKeys> {
    let pins = &doc["config"];
    let text = |name: &str| pins[name].as_str().expect("string").to_string();
    let config = PlatformSigninConfig::new(
        &text("iss"),
        &format!("{}/.well-known/jwks.json", text("iss")),
        &text("aud"),
        &text("env"),
    );
    let parsed = parse_jwks(&doc["jwks"].to_string()).expect("key set");
    Verifier::new(config, StaticKeys(parsed.keys), JtiStore::new())
}

/// Percent-encodes everything outside the unreserved set.
pub fn encode(text: &str) -> String {
    text.bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
                (b as char).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect()
}

/// The callback request a browser would make for one vector step.
pub fn request_for(step: &Value) -> CallbackRequest {
    let mut query = Vec::new();
    if let Some(token) = step["token"].as_str() {
        query.push(format!("token={}", encode(token)));
    }
    if let Some(state) = step["state"].as_str() {
        query.push(format!("state={}", encode(state)));
    }
    let cookie_pairs = match step.get("cookie").filter(|c| !c.is_null()) {
        None => vec![],
        Some(cookie) => {
            let part = |n: &str| cookie.get(n).and_then(Value::as_str);
            let value = match part("state") {
                Some(state) => format!("{}.{state}", part("nonce").unwrap_or("")),
                None => part("nonce").unwrap_or("").to_string(),
            };
            vec![format!("__Host-signin={value}")]
        }
    };
    CallbackRequest {
        raw_query: query.join("&"),
        cookie_pairs,
    }
}

/// A random source that hands out `values` in order.
pub fn scripted_random(values: &[&str]) -> Random {
    let queue = Mutex::new(
        values
            .iter()
            .map(|v| v.to_string())
            .collect::<std::collections::VecDeque<_>>(),
    );
    Box::new(move || queue.lock().unwrap().pop_front().expect("a scripted value"))
}

/// A handler over the vectors' verifier with a fixed clock and a recording log.
pub fn vector_handler(mode: &str, log: Arc<Recorder>) -> SigninHandler {
    let doc = vectors();
    let now = doc["now"].as_i64().expect("now");
    SigninHandler::new(settings(mode), Arc::new(vector_verifier(&doc)), log)
        .with_clock(Box::new(move || now))
}

/// The verified claims of an accepted vector.
pub fn vector_claims(doc: &Value, name: &str) -> super::verify::VerifiedClaims {
    use super::verify::{SigninCookie, SigninRequest};
    let step = single(doc, name);
    let cookie = SigninCookie {
        nonce: step["cookie"]["nonce"].as_str().unwrap().to_string(),
        state: step["cookie"]["state"].as_str().unwrap().to_string(),
    };
    let request = SigninRequest {
        token: step["token"].as_str(),
        state: step["state"].as_str(),
        cookie: Some(&cookie),
    };
    vector_verifier(doc)
        .verify(&request, doc["now"].as_i64().unwrap())
        .expect("an accepted vector")
}

/// The cookies of a response.
pub fn cookies_of(response: &Value) -> Vec<String> {
    response
        .get("cookies")
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|c| c.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

/// The vector with this name.
pub fn single(doc: &Value, name: &str) -> Value {
    doc["vectors"]
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["name"] == name)
        .unwrap_or_else(|| panic!("vector {name}"))
        .clone()
}

#[allow(dead_code)]
fn _unused() -> Value {
    json!({})
}
