// The business's own Stripe keys, saved from the Payments page instead of set
// in the environment. They are stored in one AWS Secrets Manager secret, never
// in the domain's database or its journal, and they are never logged, echoed in
// a response or put in an error message.
//
// The secret's `SecretString` is a JSON document with one entry per mode:
//
//   {"test": {"secret_key": "...", "publishable_key": "...",
//             "webhook_secret": "...", "webhook_endpoint_id": "...",
//             "saved_at": "2026-09-26T05:00:00Z"},
//    "live": {...}}
//
// The secret's name comes from `PAYMENTS_ACCOUNT_SECRET_ID`. On AWS, where the
// task role must be allowed `GetSecretValue`, `PutSecretValue`, `CreateSecret`
// and `DescribeSecret` on that one secret, an unset variable means the name
// `lifeadelics-payments-account`. Anywhere else an unset variable means no
// store, so nothing can be saved and only environment keys are used.
//
// Reads go through a short cache so a request does not call Secrets Manager
// every time; a save or a disconnect invalidates it at once.

use crate::secrets::AwsSecretFetcher;
use serde_json::{json, Value};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

/// The secret's name when `PAYMENTS_ACCOUNT_SECRET_ID` is unset on AWS.
pub const DEFAULT_SECRET_ID: &str = "lifeadelics-payments-account";
const CACHE_TTL: Duration = Duration::from_secs(60);

/// What is saved for one mode. Deliberately not `Debug`: it holds secrets.
#[derive(Clone, Default)]
pub struct StoredKeys {
    pub secret_key: String,
    pub publishable_key: String,
    pub webhook_secret: String,
    pub webhook_endpoint_id: String,
    pub saved_at: String,
}

impl StoredKeys {
    fn from_json(value: &Value) -> Self {
        let text = |field: &str| value.get(field).and_then(|v| v.as_str()).unwrap_or_default().to_string();
        Self { secret_key: text("secret_key"), publishable_key: text("publishable_key"), webhook_secret: text("webhook_secret"), webhook_endpoint_id: text("webhook_endpoint_id"), saved_at: text("saved_at") }
    }

    fn to_json(&self) -> Value {
        json!({
            "secret_key": self.secret_key,
            "publishable_key": self.publishable_key,
            "webhook_secret": self.webhook_secret,
            "webhook_endpoint_id": self.webhook_endpoint_id,
            "saved_at": self.saved_at,
        })
    }
}

/// Everything saved, one entry per mode.
#[derive(Clone, Default)]
pub struct StoredDocument {
    pub test: Option<StoredKeys>,
    pub live: Option<StoredKeys>,
}

impl StoredDocument {
    fn from_json(value: &Value) -> Self {
        let entry = |mode: &str| value.get(mode).filter(|v| v.is_object()).map(StoredKeys::from_json);
        Self { test: entry("test"), live: entry("live") }
    }

    fn to_json(&self) -> Value {
        let mut document = serde_json::Map::new();
        for (mode, keys) in [("test", &self.test), ("live", &self.live)] {
            if let Some(keys) = keys {
                document.insert(mode.to_string(), keys.to_json());
            }
        }
        Value::Object(document)
    }

    /// The entry saved for `mode` ("test" or "live").
    pub fn mode(&self, mode: &str) -> Option<&StoredKeys> {
        if mode == "live" { self.live.as_ref() } else { self.test.as_ref() }
    }

    /// Replaces (or with `None` removes) the entry for `mode`.
    pub fn set(&mut self, mode: &str, keys: Option<StoredKeys>) {
        if mode == "live" { self.live = keys } else { self.test = keys }
    }

    /// Every webhook signing secret saved, for either mode.
    pub fn webhook_secrets(&self) -> impl Iterator<Item = &str> {
        [self.test.as_ref(), self.live.as_ref()].into_iter().flatten().map(|k| k.webhook_secret.as_str()).filter(|s| !s.is_empty())
    }
}

/// Where the JSON document really lives. `#[async_trait]` so a test can stand
/// an in-memory copy in for Secrets Manager.
#[async_trait::async_trait]
pub trait RawStore: Send + Sync {
    /// The document's text, or `None` when nothing has been saved yet.
    async fn read(&self) -> anyhow::Result<Option<String>>;
    /// Replaces the whole document, creating the secret on the first save.
    async fn write(&self, document: &str) -> anyhow::Result<()>;
}

/// The store on AWS. The SDK client is built on first use.
pub struct AwsRawStore {
    secret_id: String,
    fetcher: tokio::sync::OnceCell<AwsSecretFetcher>,
}

impl AwsRawStore {
    /// A store over the secret named `secret_id`; nothing is fetched until the first read or write.
    pub fn new(secret_id: String) -> Self {
        Self { secret_id, fetcher: tokio::sync::OnceCell::new() }
    }

    async fn fetcher(&self) -> &AwsSecretFetcher {
        self.fetcher.get_or_init(AwsSecretFetcher::from_env).await
    }
}

#[async_trait::async_trait]
impl RawStore for AwsRawStore {
    async fn read(&self) -> anyhow::Result<Option<String>> {
        self.fetcher().await.fetch_secret_string_if_present(&self.secret_id).await
    }

    async fn write(&self, document: &str) -> anyhow::Result<()> {
        self.fetcher().await.put_secret_string(&self.secret_id, document).await
    }
}

/// The document with a short read cache in front. `update` always reads fresh,
/// so two saves cannot overwrite each other with stale data, and it
/// invalidates the cache when it writes.
pub struct KeyStore {
    raw: Arc<dyn RawStore>,
    cache: Mutex<Option<(Instant, Arc<StoredDocument>)>>,
}

impl KeyStore {
    /// A cached view over `raw`, starting with an empty cache.
    pub fn new(raw: Arc<dyn RawStore>) -> Self {
        Self { raw, cache: Mutex::new(None) }
    }

    fn cached(&self) -> Option<Arc<StoredDocument>> {
        let cache = self.cache.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        cache.as_ref().filter(|(at, _)| at.elapsed() < CACHE_TTL).map(|(_, document)| document.clone())
    }

    /// The document, from the cache when it is under a minute old.
    pub async fn document(&self) -> anyhow::Result<Arc<StoredDocument>> {
        match self.cached() {
            Some(document) => Ok(document),
            None => self.refresh().await,
        }
    }

    /// The document as it is now, bypassing and refilling the cache.
    pub async fn refresh(&self) -> anyhow::Result<Arc<StoredDocument>> {
        let text = self.raw.read().await?;
        let document = match text {
            Some(text) => StoredDocument::from_json(&serde_json::from_str::<Value>(&text).map_err(|_| anyhow::anyhow!("the stored payment keys are not valid JSON"))?),
            None => StoredDocument::default(),
        };
        let document = Arc::new(document);
        *self.cache.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = Some((Instant::now(), document.clone()));
        Ok(document)
    }

    /// Reads the current document, applies `change` and writes it back, then
    /// drops the cache so the next read sees the new document.
    pub async fn update(&self, change: impl FnOnce(&mut StoredDocument)) -> anyhow::Result<()> {
        let current = self.refresh().await?;
        let mut document = (*current).clone();
        change(&mut document);
        let text = document.to_json().to_string();
        let written = self.raw.write(&text).await;
        self.invalidate();
        written
    }

    /// Forgets the cached document.
    pub fn invalidate(&self) {
        *self.cache.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = None;
    }
}

/// The secret's name for this process, or `None` when there is no store.
fn secret_id_from_env() -> Option<String> {
    let configured = std::env::var("PAYMENTS_ACCOUNT_SECRET_ID").unwrap_or_default();
    if !configured.trim().is_empty() {
        return Some(configured.trim().to_string());
    }
    let on_aws = ["ECS_CONTAINER_METADATA_URI_V4", "AWS_LAMBDA_FUNCTION_NAME"].iter().any(|name| std::env::var(name).is_ok_and(|v| !v.is_empty()));
    on_aws.then(|| DEFAULT_SECRET_ID.to_string())
}

/// The process-wide store, built once so its cache is shared by every request.
pub fn default_store() -> Option<Arc<KeyStore>> {
    static STORE: OnceLock<Option<Arc<KeyStore>>> = OnceLock::new();
    STORE.get_or_init(|| secret_id_from_env().map(|id| Arc::new(KeyStore::new(Arc::new(AwsRawStore::new(id)))))).clone()
}

/// `YYYY-MM-DDTHH:MM:SSZ` for a Unix time in seconds (proleptic Gregorian,
/// after Howard Hinnant's civil-from-days).
pub fn utc_timestamp(seconds: u64) -> String {
    let (days, rest) = ((seconds / 86_400) as i64, seconds % 86_400);
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let day_of_era = z.rem_euclid(146_097);
    let year_of_era = (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_shifted = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_shifted + 2) / 5 + 1;
    let month = if month_shifted < 10 { month_shifted + 3 } else { month_shifted - 9 };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z", rest / 3_600, rest % 3_600 / 60, rest % 60)
}

/// The current time as `utc_timestamp` writes it.
pub fn now_timestamp() -> String {
    utc_timestamp(std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs())
}

/// An in-memory stand-in for Secrets Manager that counts its calls, for the
/// key store's own tests and the payments route tests.
#[cfg(test)]
#[derive(Default)]
pub(crate) struct MemoryStore {
    pub document: Mutex<Option<String>>,
    pub reads: std::sync::atomic::AtomicUsize,
    pub writes: std::sync::atomic::AtomicUsize,
    /// While set, every write fails, like a secret the task may not write.
    pub fail_writes: std::sync::atomic::AtomicBool,
}

#[cfg(test)]
#[async_trait::async_trait]
impl RawStore for MemoryStore {
    async fn read(&self) -> anyhow::Result<Option<String>> {
        self.reads.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        Ok(self.document.lock().unwrap().clone())
    }

    async fn write(&self, document: &str) -> anyhow::Result<()> {
        self.writes.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        if self.fail_writes.load(std::sync::atomic::Ordering::SeqCst) {
            return Err(anyhow::anyhow!("writing the secret failed"));
        }
        *self.document.lock().unwrap() = Some(document.to_string());
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::Ordering;

    fn keys(secret: &str) -> StoredKeys {
        StoredKeys { secret_key: secret.into(), publishable_key: "pk_test_x".into(), webhook_secret: "whsec_x".into(), webhook_endpoint_id: "we_1".into(), saved_at: "2026-09-26T05:00:00Z".into() }
    }

    #[tokio::test]
    async fn reads_come_from_the_cache_until_a_write_invalidates_it() {
        let raw = Arc::new(MemoryStore::default());
        let store = KeyStore::new(raw.clone());
        assert!(store.document().await.unwrap().test.is_none());
        assert!(store.document().await.unwrap().test.is_none());
        assert_eq!(raw.reads.load(Ordering::SeqCst), 1, "the second read was served from the cache");

        store.update(|doc| doc.set("test", Some(keys("rk_test_one")))).await.unwrap();
        let reads_after_update = raw.reads.load(Ordering::SeqCst);
        let document = store.document().await.unwrap();
        assert_eq!(document.test.as_ref().unwrap().secret_key, "rk_test_one", "the write invalidated the cache");
        assert_eq!(raw.reads.load(Ordering::SeqCst), reads_after_update + 1);
        assert_eq!(raw.writes.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn the_stored_json_has_exactly_the_agreed_shape() {
        let raw = Arc::new(MemoryStore::default());
        let store = KeyStore::new(raw.clone());
        store.update(|doc| doc.set("live", Some(keys("rk_live_one")))).await.unwrap();
        let stored: serde_json::Value = serde_json::from_str(raw.document.lock().unwrap().as_ref().unwrap()).unwrap();
        assert!(stored.get("test").is_none(), "an unsaved mode has no entry");
        let live = stored["live"].as_object().unwrap();
        let mut names: Vec<&str> = live.keys().map(String::as_str).collect();
        names.sort_unstable();
        assert_eq!(names, ["publishable_key", "saved_at", "secret_key", "webhook_endpoint_id", "webhook_secret"]);
    }

    #[tokio::test]
    async fn an_unreadable_document_is_an_error_that_does_not_quote_it() {
        let raw = Arc::new(MemoryStore::default());
        *raw.document.lock().unwrap() = Some("rk_live_SECRET not json".to_string());
        let error = KeyStore::new(raw).document().await.err().expect("an error").to_string();
        assert!(!error.contains("rk_live_SECRET"), "{error}");
    }

    #[test]
    fn timestamps_are_iso_8601_utc() {
        assert_eq!(utc_timestamp(0), "1970-01-01T00:00:00Z");
        assert_eq!(utc_timestamp(1_782_450_000), "2026-06-26T05:00:00Z");
        assert_eq!(utc_timestamp(951_782_400), "2000-02-29T00:00:00Z");
    }
}
