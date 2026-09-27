//! Per-address sliding-window rate limits for the public write routes a stranger can abuse,
//! enforced in `server.rs` before dispatch so a refused request costs no Postgres lock or run.

use axum::http::header::{HeaderValue, CONTENT_TYPE, RETRY_AFTER};
use axum::http::{HeaderMap, HeaderName, StatusCode};
use axum::response::{IntoResponse, Response};
use serde_json::json;
use std::collections::{BTreeMap, HashMap, VecDeque};
use std::net::{IpAddr, Ipv6Addr};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

const UNKNOWN_CLIENT: &str = "unknown";

const DEFAULT_WINDOW_SECONDS: u64 = 3600;
const DEFAULT_SUBSCRIBE: usize = 10;
const DEFAULT_REGISTER: usize = 15;
const DEFAULT_MAX_KEYS: usize = 10_000;

/// The outcome of counting one request against a window.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Decision {
    /// Whether the request may proceed; when true it has been recorded.
    pub allowed: bool,
    /// Requests still allowed in the current window after this one.
    pub remaining: usize,
    /// Whole seconds until a refused caller may try again; 0 when allowed.
    pub retry_after_secs: u64,
}

struct Entry {
    stamps: VecDeque<Instant>,
    seq: u64,
}

// `check` takes the current instant so tests move time by hand instead of sleeping.
pub struct SlidingWindow {
    limit: usize,
    window: Duration,
    max_keys: usize,
    entries: HashMap<String, Entry>,
    // Keys ordered by the sequence of their last allowed request, oldest first. An active key is
    // re-inserted at the end on every allowed request, so the first entry is always the least
    // recently active key and expired keys form a prefix.
    recency: BTreeMap<u64, String>,
    next_seq: u64,
}

impl SlidingWindow {
    // A zero `limit` or `max_keys` is raised to 1.
    pub fn new(limit: usize, window: Duration, max_keys: usize) -> Self {
        Self {
            limit: limit.max(1),
            window,
            max_keys: max_keys.max(1),
            entries: HashMap::new(),
            recency: BTreeMap::new(),
            next_seq: 0,
        }
    }

    pub fn check(&mut self, key: &str, now: Instant) -> Decision {
        let window = self.window;
        match self.entries.get_mut(key) {
            Some(entry) => {
                while entry.stamps.front().is_some_and(|s| now.saturating_duration_since(*s) >= window) {
                    entry.stamps.pop_front();
                }
                if entry.stamps.len() >= self.limit {
                    let oldest = entry.stamps.front().copied().unwrap_or(now);
                    let wait = window.saturating_sub(now.saturating_duration_since(oldest));
                    let retry_after_secs = u64::try_from(wait.as_millis().div_ceil(1000)).unwrap_or(u64::MAX).max(1);
                    return Decision { allowed: false, remaining: 0, retry_after_secs };
                }
            }
            None => self.make_room(now),
        }
        self.record(key, now)
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        self.entries.len()
    }

    fn record(&mut self, key: &str, now: Instant) -> Decision {
        let seq = self.next_seq;
        self.next_seq += 1;
        let remaining = match self.entries.get_mut(key) {
            Some(entry) => {
                self.recency.remove(&entry.seq);
                entry.seq = seq;
                entry.stamps.push_back(now);
                self.limit - entry.stamps.len()
            }
            None => {
                self.entries.insert(key.to_string(), Entry { stamps: VecDeque::from([now]), seq });
                self.limit - 1
            }
        };
        self.recency.insert(seq, key.to_string());
        Decision { allowed: true, remaining, retry_after_secs: 0 }
    }

    // Called before adding a new key: sweeps keys whose last request left the window, and only
    // then drops the least recently active ones, so a live caller is never evicted while an idle
    // one is still held.
    fn make_room(&mut self, now: Instant) {
        if self.entries.len() < self.max_keys {
            return;
        }
        while let Some((&seq, key)) = self.recency.first_key_value() {
            let expired = self
                .entries
                .get(key)
                .and_then(|e| e.stamps.back())
                .is_none_or(|last| now.saturating_duration_since(*last) >= self.window);
            if !expired {
                break;
            }
            let key = key.clone();
            self.recency.remove(&seq);
            self.entries.remove(&key);
        }
        while self.entries.len() >= self.max_keys {
            let Some((_, key)) = self.recency.pop_first() else { break };
            self.entries.remove(&key);
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct IpNet {
    addr: IpAddr,
    prefix: u8,
}

impl IpNet {
    pub fn parse(text: &str) -> Option<Self> {
        let text = text.trim();
        let (addr_text, prefix_text) = match text.split_once('/') {
            Some((addr, prefix)) => (addr, Some(prefix)),
            None => (text, None),
        };
        let addr: IpAddr = addr_text.trim().parse().ok()?;
        let width = if addr.is_ipv4() { 32 } else { 128 };
        let prefix = match prefix_text {
            Some(p) => p.trim().parse::<u8>().ok().filter(|p| *p <= width)?,
            None => width,
        };
        Some(Self { addr, prefix })
    }

    // An IPv4-mapped IPv6 address counts as its IPv4 form.
    pub fn contains(&self, ip: IpAddr) -> bool {
        match (self.addr, ip.to_canonical()) {
            (IpAddr::V4(net), IpAddr::V4(ip)) => {
                let mask = if self.prefix == 0 { 0 } else { u32::MAX << (32 - u32::from(self.prefix)) };
                u32::from(net) & mask == u32::from(ip) & mask
            }
            (IpAddr::V6(net), IpAddr::V6(ip)) => {
                let mask = if self.prefix == 0 { 0 } else { u128::MAX << (128 - u32::from(self.prefix)) };
                u128::from(net) & mask == u128::from(ip) & mask
            }
            _ => false,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProxyAuth {
    header: HeaderName,
    secret: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ProxyTrust {
    networks: Vec<IpNet>,
    hops: usize,
    auth: Option<ProxyAuth>,
}

impl ProxyTrust {
    // `None` means the client address could not be determined safely, rather than guessed;
    // callers then share one bucket. The forwarded header is read only from a trusted source.
    pub fn client_ip(&self, peer: Option<IpAddr>, forwarded_for: Option<&str>, presented_secret: Option<&str>) -> Option<IpAddr> {
        let peer = peer.map(|p| p.to_canonical());
        if !self.trusts(peer, presented_secret) {
            return peer;
        }
        let entries: Vec<&str> = forwarded_for.unwrap_or("").split(',').map(str::trim).filter(|e| !e.is_empty()).collect();
        if entries.is_empty() {
            return peer;
        }
        for entry in entries.iter().rev().skip(self.hops) {
            let ip = entry.parse::<IpAddr>().ok()?.to_canonical();
            if !self.networks.iter().any(|net| net.contains(ip)) {
                return Some(ip);
            }
        }
        None
    }

    fn trusts(&self, peer: Option<IpAddr>, presented_secret: Option<&str>) -> bool {
        let secret_matches = match (&self.auth, presented_secret) {
            (Some(auth), Some(presented)) => constant_time_eq(auth.secret.as_bytes(), presented.as_bytes()),
            _ => false,
        };
        secret_matches || peer.is_some_and(|p| self.networks.iter().any(|net| net.contains(p)))
    }
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |diff, (x, y)| diff | (x ^ y)) == 0
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Form {
    Subscribe,
    Register,
}

impl Form {
    pub fn for_request(method: &str, path: &str) -> Option<Self> {
        match (method, path) {
            ("POST", "/newsletter/subscribers") => Some(Self::Subscribe),
            ("POST", "/registrations") => Some(Self::Register),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    enabled: bool,
    window: Duration,
    subscribe: usize,
    register: usize,
    max_keys: usize,
    trust: ProxyTrust,
}

impl Config {
    // Returns one warning per setting that was unusable and fell back to its default or was
    // dropped, rather than failing boot.
    pub fn from_lookup(get: impl Fn(&str) -> Option<String>) -> (Self, Vec<String>) {
        let mut warnings = Vec::new();
        let mut number = |name: &str, default: u64| -> u64 {
            match get(name).map(|v| v.trim().to_string()).filter(|v| !v.is_empty()) {
                None => default,
                Some(raw) => raw.parse::<u64>().ok().filter(|n| *n >= 1).unwrap_or_else(|| {
                    warnings.push(format!("{name}={raw:?} is not a positive whole number; using {default}"));
                    default
                }),
            }
        };
        let window = number("HECKS_RATE_LIMIT_WINDOW_SECONDS", DEFAULT_WINDOW_SECONDS);
        let subscribe = number("HECKS_RATE_LIMIT_SUBSCRIBE", DEFAULT_SUBSCRIBE as u64);
        let register = number("HECKS_RATE_LIMIT_REGISTER", DEFAULT_REGISTER as u64);
        let max_keys = number("HECKS_RATE_LIMIT_MAX_KEYS", DEFAULT_MAX_KEYS as u64);
        let hops = get("HECKS_TRUSTED_PROXY_HOPS").map(|v| v.trim().to_string()).filter(|v| !v.is_empty()).map_or(0, |raw| {
            raw.parse::<usize>().unwrap_or_else(|_| {
                warnings.push(format!("HECKS_TRUSTED_PROXY_HOPS={raw:?} is not a whole number; using 0"));
                0
            })
        });
        let networks = parse_networks(get("HECKS_TRUSTED_PROXIES").as_deref().unwrap_or(""), &mut warnings);
        let auth = parse_proxy_auth(get("HECKS_PROXY_AUTH_HEADER"), get("HECKS_PROXY_AUTH_SECRET"), &mut warnings);
        let enabled = !get("HECKS_RATE_LIMIT").is_some_and(|v| is_off(&v));

        let config = Self {
            enabled,
            window: Duration::from_secs(window),
            subscribe: usize::try_from(subscribe).unwrap_or(usize::MAX),
            register: usize::try_from(register).unwrap_or(usize::MAX),
            max_keys: usize::try_from(max_keys).unwrap_or(usize::MAX),
            trust: ProxyTrust { networks, hops, auth },
        };
        (config, warnings)
    }

    fn limit_for(&self, form: Form) -> usize {
        match form {
            Form::Subscribe => self.subscribe,
            Form::Register => self.register,
        }
    }
}

fn is_off(value: &str) -> bool {
    matches!(value.trim().to_ascii_lowercase().as_str(), "off" | "false" | "0" | "no" | "disabled")
}

fn parse_networks(list: &str, warnings: &mut Vec<String>) -> Vec<IpNet> {
    list.split(',')
        .map(str::trim)
        .filter(|e| !e.is_empty())
        .filter_map(|entry| {
            let net = IpNet::parse(entry);
            if net.is_none() {
                warnings.push(format!("HECKS_TRUSTED_PROXIES entry {entry:?} is not an address or CIDR range; ignored"));
            }
            net
        })
        .collect()
}

fn parse_proxy_auth(header: Option<String>, secret: Option<String>, warnings: &mut Vec<String>) -> Option<ProxyAuth> {
    let header = header.map(|v| v.trim().to_string()).filter(|v| !v.is_empty());
    let secret = secret.filter(|v| !v.is_empty());
    match (header, secret) {
        (None, None) => None,
        (Some(header), Some(secret)) => match HeaderName::from_bytes(header.to_ascii_lowercase().as_bytes()) {
            Ok(header) => Some(ProxyAuth { header, secret }),
            Err(_) => {
                warnings.push(format!("HECKS_PROXY_AUTH_HEADER {header:?} is not a valid header name; proxy authentication is off"));
                None
            }
        },
        _ => {
            warnings.push("HECKS_PROXY_AUTH_HEADER and HECKS_PROXY_AUTH_SECRET must both be set; proxy authentication is off".to_string());
            None
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    Allowed,
    Limited {
        // Whole seconds until the oldest counted request leaves the window.
        retry_after_secs: u64,
    },
}

pub struct RateLimits {
    config: Config,
    windows: Mutex<HashMap<Form, SlidingWindow>>,
    warned_untrusted_proxy: AtomicBool,
}

impl RateLimits {
    pub fn new(config: Config) -> Self {
        Self { config, windows: Mutex::new(HashMap::new()), warned_untrusted_proxy: AtomicBool::new(false) }
    }

    pub fn from_env() -> Self {
        let (config, warnings) = Config::from_lookup(|name| std::env::var(name).ok());
        for warning in &warnings {
            crate::log::info("rate_limit_config_warning", json!({ "warning": warning }));
        }
        crate::log::info(
            "rate_limit_config",
            json!({
                "enabled": config.enabled,
                "window_seconds": config.window.as_secs(),
                "subscribe": config.subscribe,
                "register": config.register,
                "trusted_networks": config.trust.networks.len(),
                "trusted_proxy_hops": config.trust.hops,
                "proxy_auth": config.trust.auth.is_some(),
            }),
        );
        Self::new(config)
    }

    // A route that is not limited is always `Allowed`.
    pub fn check(&self, method: &str, path: &str, headers: &HeaderMap, peer: Option<IpAddr>) -> Verdict {
        self.check_at(method, path, headers, peer, Instant::now())
    }

    // `check` with the clock supplied, so tests need not sleep.
    pub fn check_at(&self, method: &str, path: &str, headers: &HeaderMap, peer: Option<IpAddr>, now: Instant) -> Verdict {
        let Some(form) = Form::for_request(method, path).filter(|_| self.config.enabled) else {
            return Verdict::Allowed;
        };
        let key = self.client_key(headers, peer);
        let decision = {
            let mut windows = self.windows.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            let config = &self.config;
            windows
                .entry(form)
                .or_insert_with(|| SlidingWindow::new(config.limit_for(form), config.window, config.max_keys))
                .check(&key, now)
        };
        if decision.allowed {
            Verdict::Allowed
        } else {
            Verdict::Limited { retry_after_secs: decision.retry_after_secs }
        }
    }

    fn client_key(&self, headers: &HeaderMap, peer: Option<IpAddr>) -> String {
        let forwarded_for = joined_header(headers, "x-forwarded-for");
        let presented = self.config.trust.auth.as_ref().and_then(|auth| headers.get(&auth.header)).and_then(|v| v.to_str().ok());
        self.warn_if_proxy_untrusted(forwarded_for.as_deref(), peer, presented);
        match self.config.trust.client_ip(peer, forwarded_for.as_deref(), presented) {
            Some(ip) => bucket_key(ip),
            None => UNKNOWN_CLIENT.to_string(),
        }
    }

    // A forwarded header from a private peer that nothing trusts means a proxy sits in front of
    // the host and every visitor is being counted as that proxy. Said once, since it repeats on
    // every request.
    fn warn_if_proxy_untrusted(&self, forwarded_for: Option<&str>, peer: Option<IpAddr>, presented: Option<&str>) {
        let Some(peer) = peer.map(|p| p.to_canonical()) else { return };
        if forwarded_for.is_none() || !is_private(peer) || self.config.trust.trusts(Some(peer), presented) {
            return;
        }
        if !self.warned_untrusted_proxy.swap(true, Ordering::Relaxed) {
            crate::log::info(
                "rate_limit_untrusted_proxy",
                json!({
                    "peer": peer.to_string(),
                    "hint": "requests arrive from a private address with X-Forwarded-For but no trusted proxy is configured; \
                             set HECKS_TRUSTED_PROXIES or HECKS_PROXY_AUTH_HEADER and HECKS_PROXY_AUTH_SECRET",
                }),
            );
        }
    }
}

// Several X-Forwarded-For header lines mean the same as one comma-joined line.
fn joined_header(headers: &HeaderMap, name: &str) -> Option<String> {
    let values: Vec<String> = headers.get_all(name).iter().map(|v| String::from_utf8_lossy(v.as_bytes()).into_owned()).collect();
    if values.is_empty() {
        None
    } else {
        Some(values.join(", "))
    }
}

// IPv6 callers are counted per /64: one subscriber controls the whole prefix and could otherwise
// rotate through it for a fresh allowance on every request.
fn bucket_key(ip: IpAddr) -> String {
    match ip {
        IpAddr::V4(v4) => v4.to_string(),
        IpAddr::V6(v6) => {
            let prefix = u128::from(v6) & (u128::MAX << 64);
            format!("{}/64", Ipv6Addr::from(prefix))
        }
    }
}

fn is_private(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => v4.is_private() || v4.is_loopback() || v4.is_link_local(),
        IpAddr::V6(v6) => v6.is_loopback() || (v6.segments()[0] & 0xfe00) == 0xfc00,
    }
}

pub fn too_many_requests(retry_after_secs: u64) -> Response {
    let body = json!({ "error": "too many requests, please try again later" }).to_string();
    let mut response = (StatusCode::TOO_MANY_REQUESTS, body).into_response();
    let headers = response.headers_mut();
    headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
    headers.insert(RETRY_AFTER, HeaderValue::from(retry_after_secs));
    response
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOUR: Duration = Duration::from_secs(3600);
    const VISITOR: &str = "203.0.113.7";
    const EDGE: &str = "130.176.1.9";

    fn ip(text: &str) -> IpAddr {
        text.parse().unwrap()
    }

    fn trust(networks: &[&str], hops: usize, auth: Option<(&str, &str)>) -> ProxyTrust {
        ProxyTrust {
            networks: networks.iter().map(|n| IpNet::parse(n).unwrap()).collect(),
            hops,
            auth: auth.map(|(header, secret)| ProxyAuth { header: HeaderName::from_bytes(header.as_bytes()).unwrap(), secret: secret.to_string() }),
        }
    }

    fn config_from(pairs: &[(&str, &str)]) -> (Config, Vec<String>) {
        let map: HashMap<String, String> = pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
        Config::from_lookup(|name| map.get(name).cloned())
    }

    fn limits(pairs: &[(&str, &str)]) -> RateLimits {
        RateLimits::new(config_from(pairs).0)
    }

    fn headers(pairs: &[(&str, &str)]) -> HeaderMap {
        let mut map = HeaderMap::new();
        for (name, value) in pairs {
            map.append(HeaderName::from_bytes(name.as_bytes()).unwrap(), HeaderValue::from_str(value).unwrap());
        }
        map
    }

    #[test]
    fn allows_up_to_the_limit_then_refuses_with_the_seconds_until_the_oldest_hit_expires() {
        let start = Instant::now();
        let mut window = SlidingWindow::new(3, HOUR, 100);
        assert_eq!(window.check("a", start), Decision { allowed: true, remaining: 2, retry_after_secs: 0 });
        assert_eq!(window.check("a", start + Duration::from_secs(10)).remaining, 1);
        assert_eq!(window.check("a", start + Duration::from_secs(20)).remaining, 0);

        let refused = window.check("a", start + Duration::from_secs(30));
        assert!(!refused.allowed);
        assert_eq!(refused.retry_after_secs, 3600 - 30);
    }

    #[test]
    fn the_window_slides_so_a_hit_ages_out_individually() {
        let start = Instant::now();
        let mut window = SlidingWindow::new(2, HOUR, 100);
        window.check("a", start);
        window.check("a", start + Duration::from_secs(1800));
        assert!(!window.check("a", start + Duration::from_secs(1801)).allowed);

        let later = start + Duration::from_secs(3601);
        assert!(window.check("a", later).allowed, "the first hit is past the window");
        assert!(!window.check("a", later).allowed, "the second is still inside it");
    }

    #[test]
    fn keys_are_independent() {
        let now = Instant::now();
        let mut window = SlidingWindow::new(1, HOUR, 100);
        assert!(window.check("a", now).allowed);
        assert!(!window.check("a", now).allowed);
        assert!(window.check("b", now).allowed);
    }

    #[test]
    fn refused_requests_are_not_recorded_so_hammering_does_not_extend_the_lockout() {
        let start = Instant::now();
        let mut window = SlidingWindow::new(1, HOUR, 100);
        window.check("a", start);
        for second in 1..=50 {
            assert!(!window.check("a", start + Duration::from_secs(second)).allowed);
        }
        assert!(window.check("a", start + HOUR).allowed, "the one recorded hit expired on schedule");
    }

    #[test]
    fn retry_after_is_at_least_one_second_and_rounds_up() {
        let start = Instant::now();
        let mut window = SlidingWindow::new(1, Duration::from_millis(1500), 100);
        window.check("a", start);
        assert_eq!(window.check("a", start + Duration::from_millis(1)).retry_after_secs, 2);
        assert_eq!(window.check("a", start + Duration::from_millis(1499)).retry_after_secs, 1);
    }

    #[test]
    fn expired_keys_are_swept_before_live_ones_are_evicted() {
        let start = Instant::now();
        let mut window = SlidingWindow::new(1, HOUR, 3);
        window.check("old1", start);
        window.check("old2", start);
        let later = start + HOUR + Duration::from_secs(1);
        window.check("live", later);
        window.check("new1", later);
        assert_eq!(window.len(), 2, "sweeping dropped old1 and old2, not live");
        assert!(!window.check("live", later).allowed, "live was kept");
    }

    #[test]
    fn at_the_size_cap_the_least_recently_active_key_is_evicted() {
        let start = Instant::now();
        let mut window = SlidingWindow::new(1, HOUR, 3);
        for (i, key) in ["a", "b", "c", "d", "e"].iter().enumerate() {
            window.check(key, start + Duration::from_millis(i as u64));
            assert!(window.len() <= 3);
        }
        assert_eq!(window.len(), 3);
        let now = start + Duration::from_millis(10);
        assert!(window.check("a", now).allowed, "a was evicted, so it starts fresh");
        assert!(!window.check("e", now).allowed, "e is still tracked");
    }

    #[test]
    fn a_zero_limit_or_key_cap_is_raised_to_one() {
        let mut window = SlidingWindow::new(0, HOUR, 0);
        let now = Instant::now();
        assert!(window.check("a", now).allowed);
        assert!(!window.check("a", now).allowed);
        assert!(window.check("b", now).allowed);
        assert_eq!(window.len(), 1);
    }

    #[test]
    fn parses_and_matches_addresses_and_cidr_ranges() {
        let single = IpNet::parse("10.0.0.5").unwrap();
        assert!(single.contains(ip("10.0.0.5")));
        assert!(!single.contains(ip("10.0.0.6")));

        let range = IpNet::parse("10.0.0.0/8").unwrap();
        assert!(range.contains(ip("10.255.1.2")));
        assert!(!range.contains(ip("11.0.0.1")));

        let v6 = IpNet::parse("fd00::/8").unwrap();
        assert!(v6.contains(ip("fd12::1")));
        assert!(!v6.contains(ip("2001:db8::1")));
        assert!(!v6.contains(ip("10.0.0.1")), "families never match each other");

        assert!(IpNet::parse("0.0.0.0/0").unwrap().contains(ip("8.8.8.8")));
        assert!(IpNet::parse("10.0.0.0/8").unwrap().contains(ip("::ffff:10.1.1.1")), "a mapped address is its IPv4 form");
    }

    #[test]
    fn rejects_malformed_ranges() {
        for bad in ["", "banana", "10.0.0.0/33", "::1/129", "10.0.0.0/", "10.0.0/8", "/8"] {
            assert!(IpNet::parse(bad).is_none(), "{bad:?}");
        }
    }

    #[test]
    fn with_nothing_trusted_the_peer_is_the_client_and_the_header_is_ignored() {
        let none = trust(&[], 0, None);
        assert_eq!(none.client_ip(Some(ip("198.51.100.4")), Some("6.6.6.6"), None), Some(ip("198.51.100.4")));
        assert_eq!(none.client_ip(None, Some("6.6.6.6"), None), None);
    }

    #[test]
    fn an_untrusted_peer_cannot_choose_its_own_key_by_sending_a_header() {
        let proxies = trust(&["10.0.0.0/8"], 0, None);
        let from_stranger = |spoof: &str| proxies.client_ip(Some(ip("198.51.100.4")), Some(spoof), None);
        assert_eq!(from_stranger("1.1.1.1"), from_stranger("2.2.2.2"));
        assert_eq!(from_stranger("1.1.1.1"), Some(ip("198.51.100.4")));
    }

    #[test]
    fn a_trusted_peer_is_believed_and_the_rightmost_entry_is_the_client() {
        let proxies = trust(&["10.0.0.0/8"], 0, None);
        assert_eq!(proxies.client_ip(Some(ip("10.0.0.5")), Some(&format!("6.6.6.6, {VISITOR}")), None), Some(ip(VISITOR)));
    }

    #[test]
    fn a_spoofed_leading_entry_is_never_reached() {
        let proxies = trust(&["10.0.0.0/8"], 0, None);
        let forwarded = format!("6.6.6.6, 7.7.7.7, {VISITOR}, 10.0.0.9");
        assert_eq!(proxies.client_ip(Some(ip("10.0.0.5")), Some(&forwarded), None), Some(ip(VISITOR)));
    }

    #[test]
    fn a_visitor_cannot_pick_their_key_by_varying_the_spoofed_part() {
        let proxies = trust(&["10.0.0.0/8"], 0, None);
        let key = |spoof: &str| proxies.client_ip(Some(ip("10.0.0.5")), Some(&format!("{spoof}, {VISITOR}")), None);
        assert_eq!(key("1.1.1.1"), key("2.2.2.2"));
    }

    #[test]
    fn trusted_proxies_inside_the_header_are_skipped_from_the_right() {
        let proxies = trust(&["10.0.0.0/8", "172.16.0.0/12"], 0, None);
        let forwarded = format!("6.6.6.6, {VISITOR}, 172.16.0.3, 10.0.0.9");
        assert_eq!(proxies.client_ip(Some(ip("10.0.0.5")), Some(&forwarded), None), Some(ip(VISITOR)));
    }

    #[test]
    fn the_shared_secret_authenticates_a_request_from_an_unlisted_peer() {
        let cdn = trust(&[], 1, Some(("x-origin-secret", "s3cret")));
        let forwarded = format!("6.6.6.6, {VISITOR}, {EDGE}");
        assert_eq!(cdn.client_ip(Some(ip("10.0.0.5")), Some(&forwarded), Some("s3cret")), Some(ip(VISITOR)));
        assert_eq!(cdn.client_ip(Some(ip("10.0.0.5")), Some(&forwarded), Some("wrong")), Some(ip("10.0.0.5")));
        assert_eq!(cdn.client_ip(Some(ip("10.0.0.5")), Some(&forwarded), None), Some(ip("10.0.0.5")));
        assert_eq!(cdn.client_ip(Some(ip("10.0.0.5")), Some(&forwarded), Some("s3cret-and-more")), Some(ip("10.0.0.5")));
    }

    #[test]
    fn hops_skip_the_rightmost_entries_added_by_unlisted_proxies() {
        let cdn = trust(&[], 1, Some(("x-origin-secret", "s")));
        let one = format!("6.6.6.6, 7.7.7.7, {VISITOR}, {EDGE}");
        assert_eq!(cdn.client_ip(None, Some(&one), Some("s")), Some(ip(VISITOR)));

        let two = trust(&[], 2, Some(("x-origin-secret", "s")));
        let forwarded = format!("6.6.6.6, {VISITOR}, {EDGE}, 130.176.2.2");
        assert_eq!(two.client_ip(None, Some(&forwarded), Some("s")), Some(ip(VISITOR)));
    }

    #[test]
    fn a_header_shorter_than_the_walk_implies_yields_no_client() {
        let cdn = trust(&[], 1, Some(("x-origin-secret", "s")));
        assert_eq!(cdn.client_ip(Some(ip("127.0.0.1")), Some("6.6.6.6"), Some("s")), None);
        let listed = trust(&["10.0.0.0/8"], 0, None);
        assert_eq!(listed.client_ip(Some(ip("10.0.0.5")), Some("10.0.0.9, 10.0.0.8"), None), None, "every entry is one of ours");
    }

    #[test]
    fn a_client_entry_that_is_not_an_address_yields_no_client() {
        let proxies = trust(&["10.0.0.0/8"], 0, None);
        assert_eq!(proxies.client_ip(Some(ip("10.0.0.5")), Some("6.6.6.6, not-an-ip"), None), None);
    }

    #[test]
    fn a_trusted_peer_with_no_header_is_its_own_client() {
        let proxies = trust(&["127.0.0.1"], 0, None);
        assert_eq!(proxies.client_ip(Some(ip("127.0.0.1")), None, None), Some(ip("127.0.0.1")));
        assert_eq!(proxies.client_ip(Some(ip("127.0.0.1")), Some(" , "), None), Some(ip("127.0.0.1")));
    }

    #[test]
    fn tolerates_spaces_empty_entries_and_ipv6() {
        let proxies = trust(&["10.0.0.0/8"], 0, None);
        let forwarded = " 9.9.9.9 ,, 2001:db8::1 , 10.0.0.9 ";
        assert_eq!(proxies.client_ip(Some(ip("10.0.0.5")), Some(forwarded), None), Some(ip("2001:db8::1")));
    }

    #[test]
    fn a_mapped_peer_is_matched_as_its_ipv4_form() {
        let proxies = trust(&["10.0.0.0/8"], 0, None);
        assert_eq!(proxies.client_ip(Some(ip("::ffff:10.0.0.5")), Some(VISITOR), None), Some(ip(VISITOR)));
    }

    #[test]
    fn ipv6_callers_are_bucketed_by_their_64() {
        assert_eq!(bucket_key(ip("2001:db8:1:2:aaaa:bbbb:cccc:dddd")), bucket_key(ip("2001:db8:1:2::1")));
        assert_ne!(bucket_key(ip("2001:db8:1:2::1")), bucket_key(ip("2001:db8:1:3::1")));
        assert_eq!(bucket_key(ip("203.0.113.7")), "203.0.113.7");
    }

    #[test]
    fn defaults_are_on_with_no_trust() {
        let (config, warnings) = config_from(&[]);
        assert!(warnings.is_empty());
        assert!(config.enabled);
        assert_eq!(config.window, HOUR);
        assert_eq!((config.subscribe, config.register, config.max_keys), (10, 15, 10_000));
        assert_eq!(config.trust, ProxyTrust::default());
    }

    #[test]
    fn every_setting_can_be_tuned() {
        let (config, warnings) = config_from(&[
            ("HECKS_RATE_LIMIT_WINDOW_SECONDS", " 60 "),
            ("HECKS_RATE_LIMIT_SUBSCRIBE", "3"),
            ("HECKS_RATE_LIMIT_REGISTER", "4"),
            ("HECKS_RATE_LIMIT_MAX_KEYS", "50"),
            ("HECKS_TRUSTED_PROXIES", "10.0.0.0/8, 127.0.0.1"),
            ("HECKS_TRUSTED_PROXY_HOPS", "1"),
            ("HECKS_PROXY_AUTH_HEADER", "X-Origin-Secret"),
            ("HECKS_PROXY_AUTH_SECRET", "s3cret"),
        ]);
        assert!(warnings.is_empty(), "{warnings:?}");
        assert_eq!(config.window, Duration::from_secs(60));
        assert_eq!((config.subscribe, config.register, config.max_keys), (3, 4, 50));
        assert_eq!(config.trust, trust(&["10.0.0.0/8", "127.0.0.1"], 1, Some(("x-origin-secret", "s3cret"))));
    }

    #[test]
    fn off_values_turn_the_limits_off_and_anything_else_leaves_them_on() {
        for off in ["off", "OFF", " false ", "0", "no", "disabled"] {
            assert!(!config_from(&[("HECKS_RATE_LIMIT", off)]).0.enabled, "{off:?}");
        }
        for on in ["on", "true", "1", ""] {
            assert!(config_from(&[("HECKS_RATE_LIMIT", on)]).0.enabled, "{on:?}");
        }
    }

    #[test]
    fn unusable_values_fall_back_and_are_reported() {
        let (config, warnings) = config_from(&[
            ("HECKS_RATE_LIMIT_SUBSCRIBE", "0"),
            ("HECKS_RATE_LIMIT_REGISTER", "lots"),
            ("HECKS_RATE_LIMIT_WINDOW_SECONDS", "-5"),
            ("HECKS_TRUSTED_PROXY_HOPS", "two"),
            ("HECKS_TRUSTED_PROXIES", "10.0.0.0/8, banana"),
        ]);
        assert_eq!((config.subscribe, config.register, config.window), (10, 15, HOUR));
        assert_eq!(config.trust.hops, 0);
        assert_eq!(config.trust.networks.len(), 1);
        assert_eq!(warnings.len(), 5, "{warnings:?}");
    }

    #[test]
    fn proxy_authentication_needs_both_a_header_and_a_secret() {
        for pairs in [&[("HECKS_PROXY_AUTH_HEADER", "x-secret")][..], &[("HECKS_PROXY_AUTH_SECRET", "s")][..]] {
            let (config, warnings) = config_from(pairs);
            assert!(config.trust.auth.is_none());
            assert_eq!(warnings.len(), 1);
        }
        let (config, warnings) = config_from(&[("HECKS_PROXY_AUTH_HEADER", "not a header"), ("HECKS_PROXY_AUTH_SECRET", "s")]);
        assert!(config.trust.auth.is_none());
        assert_eq!(warnings.len(), 1);
    }

    #[test]
    fn only_the_public_write_routes_are_limited() {
        assert_eq!(Form::for_request("POST", "/newsletter/subscribers"), Some(Form::Subscribe));
        assert_eq!(Form::for_request("POST", "/registrations"), Some(Form::Register));
        for (method, path) in [
            ("GET", "/newsletter/subscribers"),
            ("GET", "/newsletter/subscribers/confirm"),
            ("GET", "/newsletter/subscribers/unsubscribe"),
            ("GET", "/registrations"),
            ("GET", "/registrations/REG-1"),
            ("POST", "/registrations/REG-1/complete"),
            ("POST", "/webhooks/stripe"),
            ("POST", "/events"),
            ("POST", "/members"),
            ("POST", "/newsletter/subscribers/"),
        ] {
            assert_eq!(Form::for_request(method, path), None, "{method} {path}");
        }
    }

    #[test]
    fn each_route_has_its_own_budget_per_client() {
        let limits = limits(&[("HECKS_RATE_LIMIT_SUBSCRIBE", "2"), ("HECKS_RATE_LIMIT_REGISTER", "1")]);
        let (none, peer, now) = (HeaderMap::new(), Some(ip("198.51.100.4")), Instant::now());
        let hit = |path: &str| limits.check_at("POST", path, &none, peer, now);

        assert_eq!(hit("/newsletter/subscribers"), Verdict::Allowed);
        assert_eq!(hit("/newsletter/subscribers"), Verdict::Allowed);
        assert_eq!(hit("/newsletter/subscribers"), Verdict::Limited { retry_after_secs: 3600 });
        assert_eq!(hit("/registrations"), Verdict::Allowed, "subscribe being spent does not touch register");
        assert_eq!(hit("/registrations"), Verdict::Limited { retry_after_secs: 3600 });
    }

    #[test]
    fn the_window_rolls_over() {
        let limits = limits(&[("HECKS_RATE_LIMIT_REGISTER", "1"), ("HECKS_RATE_LIMIT_WINDOW_SECONDS", "60")]);
        let (none, peer, start) = (HeaderMap::new(), Some(ip("198.51.100.4")), Instant::now());
        let at = |secs: u64| limits.check_at("POST", "/registrations", &none, peer, start + Duration::from_secs(secs));

        assert_eq!(at(0), Verdict::Allowed);
        assert_eq!(at(10), Verdict::Limited { retry_after_secs: 50 });
        assert_eq!(at(60), Verdict::Allowed);
    }

    #[test]
    fn unlimited_routes_and_disabled_limits_always_allow() {
        let on = limits(&[("HECKS_RATE_LIMIT_SUBSCRIBE", "1")]);
        let (none, peer, now) = (HeaderMap::new(), Some(ip("198.51.100.4")), Instant::now());
        for _ in 0..5 {
            assert_eq!(on.check_at("GET", "/newsletter/subscribers", &none, peer, now), Verdict::Allowed);
            assert_eq!(on.check_at("POST", "/webhooks/stripe", &none, peer, now), Verdict::Allowed);
        }

        let off = limits(&[("HECKS_RATE_LIMIT", "off"), ("HECKS_RATE_LIMIT_SUBSCRIBE", "1")]);
        for _ in 0..5 {
            assert_eq!(off.check_at("POST", "/newsletter/subscribers", &none, peer, now), Verdict::Allowed);
        }
    }

    #[test]
    fn a_spoofed_header_from_an_untrusted_peer_does_not_reset_the_count() {
        let limits = limits(&[("HECKS_RATE_LIMIT_SUBSCRIBE", "1"), ("HECKS_TRUSTED_PROXIES", "10.0.0.0/8")]);
        let (peer, now) = (Some(ip("198.51.100.4")), Instant::now());
        let send = |spoof: &str| limits.check_at("POST", "/newsletter/subscribers", &headers(&[("x-forwarded-for", spoof)]), peer, now);

        assert_eq!(send("1.1.1.1"), Verdict::Allowed);
        assert!(matches!(send("2.2.2.2"), Verdict::Limited { .. }));
    }

    #[test]
    fn behind_the_shared_secret_each_visitor_has_their_own_budget() {
        let limits = limits(&[
            ("HECKS_RATE_LIMIT_REGISTER", "1"),
            ("HECKS_PROXY_AUTH_HEADER", "x-origin-secret"),
            ("HECKS_PROXY_AUTH_SECRET", "s3cret"),
            ("HECKS_TRUSTED_PROXY_HOPS", "1"),
        ]);
        let (alb, now) = (Some(ip("10.0.0.5")), Instant::now());
        let from = |spoof: &str, visitor: &str| {
            let forwarded = format!("{spoof}, {visitor}, {EDGE}");
            limits.check_at("POST", "/registrations", &headers(&[("x-origin-secret", "s3cret"), ("x-forwarded-for", &forwarded)]), alb, now)
        };

        assert_eq!(from("1.1.1.1", VISITOR), Verdict::Allowed);
        assert!(matches!(from("2.2.2.2", VISITOR), Verdict::Limited { .. }), "a new spoofed entry is not a new visitor");
        assert_eq!(from("2.2.2.2", "198.51.100.4"), Verdict::Allowed, "another visitor has their own count");
    }

    #[test]
    fn requests_whose_client_cannot_be_determined_share_one_bucket() {
        let limits = limits(&[("HECKS_RATE_LIMIT_REGISTER", "1"), ("HECKS_TRUSTED_PROXIES", "10.0.0.0/8")]);
        let now = Instant::now();
        let short = headers(&[("x-forwarded-for", "10.0.0.9")]);
        assert_eq!(limits.check_at("POST", "/registrations", &short, Some(ip("10.0.0.5")), now), Verdict::Allowed);
        assert!(matches!(limits.check_at("POST", "/registrations", &short, Some(ip("10.0.0.6")), now), Verdict::Limited { .. }));
    }

    #[test]
    fn repeated_forwarded_header_lines_read_as_one_list() {
        let limits = limits(&[("HECKS_RATE_LIMIT_REGISTER", "1"), ("HECKS_TRUSTED_PROXIES", "10.0.0.0/8")]);
        let (peer, now) = (Some(ip("10.0.0.5")), Instant::now());
        let split = headers(&[("x-forwarded-for", "6.6.6.6"), ("x-forwarded-for", VISITOR)]);
        let joined = headers(&[("x-forwarded-for", &format!("9.9.9.9, {VISITOR}"))]);
        assert_eq!(limits.check_at("POST", "/registrations", &split, peer, now), Verdict::Allowed);
        assert!(matches!(limits.check_at("POST", "/registrations", &joined, peer, now), Verdict::Limited { .. }));
    }

    #[tokio::test]
    async fn the_refusal_is_a_429_with_retry_after_and_the_json_error_shape() {
        let response = too_many_requests(120);
        assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
        assert_eq!(response.headers()[RETRY_AFTER], "120");
        assert_eq!(response.headers()[CONTENT_TYPE], "application/json");
        let bytes = axum::body::to_bytes(response.into_body(), 4096).await.unwrap();
        let body: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(body, json!({ "error": "too many requests, please try again later" }));
    }
}
