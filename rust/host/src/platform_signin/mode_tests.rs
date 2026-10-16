//! The modes, the routes each owns, and the guarantee that off means off.

use std::sync::Arc;

use serde_json::{json, Value};

use super::extension::{extensions_for, PlatformSignin, Route};
use super::wiring_support::*;
use crate::extension::HostExtension;

fn event(method: &str, path: &str, query: &str) -> Value {
    json!({"requestContext": {"http": {"method": method}}, "rawPath": path, "rawQueryString": query, "headers": {}})
}

fn extension(mode: &str) -> PlatformSignin {
    PlatformSignin::from_env_map(&env_map(mode)).unwrap().expect("on")
}

fn with_handler(mode: &str) -> PlatformSignin {
    PlatformSignin::new(vector_handler(mode, Arc::new(Recorder::default())).with_random(scripted_random(&[NONCE_A, STATE_A])))
}

async fn answer(ext: &PlatformSignin, event: &Value) -> Option<Value> {
    ext.route_event(event, &FakeMembers::default()).await
}

/// Every route the host answers itself today, plus lookalikes.
const EXISTING: &[(&str, &str)] = &[
    ("GET", "/login"), ("POST", "/logout"), ("POST", "/accounts/logout"), ("GET", "/accounts/me"), ("GET", "/members"),
    ("POST", "/members"), ("POST", "/signups"), ("POST", "/members/disable"), ("POST", "/members/enable"),
    ("POST", "/members/role"), ("POST", "/members/delete"), ("GET", "/accounts/sso-token"), ("GET", "/auth/google/callback"),
    ("GET", "/admin/members"), ("POST", "/admin/members"), ("GET", "/"), ("GET", "/api/anything"), ("POST", "/newsletter/subscribers"),
    ("POST", "/registrations"), ("POST", "/webhooks/stripe"), ("GET", "/auth/platform/"), ("GET", "/auth/platformx"),
    ("GET", "/auth"), ("GET", "/auth/google/"), ("POST", "/auth/platform"), ("POST", "/auth/platform/callback"),
    ("PUT", "/auth/platform"), ("HEAD", "/auth/platform/callback"), ("GET", "/AUTH/PLATFORM"),
];

// ---- off means off ----

#[test]
fn an_unset_switch_installs_nothing() {
    let mut vars = env_map("alongside");
    vars.remove("PLATFORM_SIGNIN");
    assert!(extensions_for(&vars).is_empty());
    assert!(extensions_for(&Default::default()).is_empty());
    assert!(PlatformSignin::from_env_map(&vars).unwrap().is_none());
}

#[test]
fn the_default_extension_list_is_unchanged_when_the_switch_is_unset() {
    let installed = crate::extension::default_extensions_from(&Default::default());
    assert_eq!(installed.len(), 1);
    assert!(installed[0].rate_rules().iter().all(|rule| !rule.path.starts_with("/auth")));
}

#[test]
fn a_switched_on_site_adds_exactly_one_extension() {
    assert_eq!(crate::extension::default_extensions_from(&env_map("default")).len(), 2);
}

#[tokio::test]
async fn off_means_the_new_paths_reach_the_hosts_own_handling() {
    // With no extension installed the loop in `web::render` finds nobody; this pins what a
    // request for the new path meets instead: the hosts own routes, which know nothing of it.
    let installed = crate::extension::default_extensions_from(&Default::default());
    assert_eq!(installed.len(), 1);
    assert!(installed.iter().all(|e| e.rate_rules().iter().all(|r| r.path != "/auth/platform")));
}

// ---- alongside ----

#[tokio::test]
async fn alongside_owns_the_two_platform_paths_and_leaves_google_alone() {
    let ext = with_handler("alongside");
    assert_eq!(ext.classify(&event("GET", "/auth/platform", "")), Some(Route::Start));
    assert_eq!(ext.classify(&event("GET", "/auth/platform/callback", "token=x")), Some(Route::Callback));
    for query in ["", "via=google", "via=other", "x=1"] {
        assert_eq!(ext.classify(&event("GET", "/auth/google", query)), None, "{query}");
    }
    assert!(answer(&ext, &event("GET", "/auth/google", "")).await.is_none());
}

#[tokio::test]
async fn alongside_start_goes_to_the_issuer() {
    let response = answer(&with_handler("alongside"), &event("GET", "/auth/platform", "")).await.unwrap();
    assert_eq!(response["statusCode"], 302);
    assert!(response["headers"]["location"].as_str().unwrap().starts_with("https://issuer.example/sso/authorize?"));
}

// ---- default ----

#[tokio::test]
async fn default_sends_google_sign_in_to_the_issuer() {
    let ext = with_handler("default");
    assert_eq!(ext.classify(&event("GET", "/auth/google", "")), Some(Route::Start));
    let response = answer(&ext, &event("GET", "/auth/google", "")).await.unwrap();
    assert!(response["headers"]["location"].as_str().unwrap().starts_with("https://issuer.example/sso/authorize?"));
}

#[test]
fn default_keeps_the_break_glass_to_the_existing_google_flow() {
    let ext = with_handler("default");
    for query in ["via=google", "a=1&via=google", "via=google&a=1"] {
        assert_eq!(ext.classify(&event("GET", "/auth/google", query)), None, "{query}");
    }
}

#[test]
fn default_only_treats_the_exact_value_google_as_the_break_glass() {
    let ext = with_handler("default");
    for query in ["via=Google", "via=", "via=other", "via", "next=via=google"] {
        assert_eq!(ext.classify(&event("GET", "/auth/google", query)), Some(Route::Start), "{query}");
    }
}

#[test]
fn default_also_answers_the_platform_paths() {
    let ext = with_handler("default");
    assert_eq!(ext.classify(&event("GET", "/auth/platform", "")), Some(Route::Start));
    assert_eq!(ext.classify(&event("GET", "/auth/platform/callback", "")), Some(Route::Callback));
}

#[test]
fn the_google_callback_is_never_taken_over() {
    for mode in ["alongside", "default"] {
        assert_eq!(with_handler(mode).classify(&event("GET", "/auth/google/callback", "code=1&state=2")), None);
    }
}

// ---- no other route is touched ----

#[tokio::test]
async fn no_existing_route_or_method_is_answered_in_either_mode() {
    for mode in ["alongside", "default"] {
        let ext = with_handler(mode);
        for (method, path) in EXISTING {
            assert!(answer(&ext, &event(method, path, "via=google&x=1")).await.is_none(), "{mode} {method} {path}");
        }
    }
}

#[tokio::test]
async fn a_post_to_google_is_left_to_the_host_even_in_default_mode() {
    assert!(answer(&with_handler("default"), &event("POST", "/auth/google", "")).await.is_none());
}

#[tokio::test]
async fn an_event_without_a_method_or_path_is_not_ours() {
    let ext = with_handler("default");
    assert!(answer(&ext, &json!({})).await.is_none());
    assert!(answer(&ext, &json!({"rawPath": "/auth/platform"})).await.is_none());
}

// ---- boot refusals ----

#[test]
fn invalid_or_partial_settings_refuse_the_boot_naming_only_variables() {
    let sentinel = "http://leaky-sentinel.example/x?secret=hunter2";
    let mut cases: Vec<(&str, std::collections::HashMap<String, String>)> = Vec::new();
    for name in ["PLATFORM_ISSUER_URL", "PLATFORM_SITE_ID", "PLATFORM_ENVIRONMENT", "SITE_URL", "SESSION_SECRET", "HECKS_SERVE_MODE"] {
        let mut missing = env_map("alongside");
        missing.remove(name);
        cases.push((name, missing));
        let mut bad = env_map("alongside");
        bad.insert(name.to_string(), sentinel.to_string());
        cases.push((name, bad));
    }
    let mut bad_mode = env_map("alongside");
    bad_mode.insert("PLATFORM_SIGNIN".into(), sentinel.into());
    cases.push(("PLATFORM_SIGNIN", bad_mode));
    for (variable, vars) in cases {
        let installed = extensions_for(&vars);
        assert_eq!(installed.len(), 1, "{variable}");
        let message = installed[0].boot_check("anything").expect_err("the boot is refused");
        assert!(message.contains(variable), "{variable}: {message}");
        assert!(!message.contains("sentinel") && !message.contains("hunter2") && !message.contains("a-long-session-secret"), "{message}");
    }
}

#[test]
fn a_good_configuration_passes_the_boot_check() {
    let installed = extensions_for(&env_map("default"));
    assert!(installed[0].boot_check("anything").is_ok());
}

// ---- rate rules ----

#[test]
fn the_start_and_the_callback_are_rate_limited_per_client() {
    let rules = extension("alongside").rate_rules();
    let find = |path: &str| rules.iter().find(|r| r.path == path).unwrap_or_else(|| panic!("a rule for {path}"));
    for path in ["/auth/platform", "/auth/platform/callback"] {
        assert_eq!(find(path).method, "GET");
        assert!(find(path).default_limit >= 10);
    }
    assert_ne!(find("/auth/platform").name, find("/auth/platform/callback").name);
    assert_ne!(find("/auth/platform").limit_env, find("/auth/platform/callback").limit_env);
}

#[test]
fn the_break_glass_path_is_not_rate_limited_by_this_extension() {
    assert!(extension("default").rate_rules().iter().all(|r| r.path != "/auth/google"));
}

// ---- hostile headers ----

#[tokio::test]
async fn host_and_forwarding_headers_change_nothing() {
    let plain = event("GET", "/auth/platform", "");
    let mut hostile = plain.clone();
    hostile["headers"] = json!({
        "host": "evil.example", "x-forwarded-host": "evil.example", "x-forwarded-proto": "http",
        "x-forwarded-for": "203.0.113.9", "forwarded": "host=evil.example;proto=http", "origin": "https://evil.example",
        "referer": "https://evil.example/"
    });
    let a = answer(&with_handler("alongside"), &plain).await.unwrap();
    let b = answer(&with_handler("alongside"), &hostile).await.unwrap();
    assert_eq!(a, b);
    assert!(!a.to_string().contains("evil"));
}

#[tokio::test]
async fn a_hostile_host_on_the_callback_still_redirects_only_to_the_landing_page() {
    let doc = vectors();
    let step = single(&doc, "valid");
    let request = request_for(&step);
    let mut e = event("GET", "/auth/platform/callback", &request.raw_query);
    e["headers"] = json!({"host": "evil.example", "x-forwarded-host": "evil.example", "cookie": request.cookie_pairs.join("; ")});
    let members = FakeMembers::resolving(Person::new("person@example.test", Some("Admin")));
    let ext = PlatformSignin::new(vector_handler("alongside", Arc::new(Recorder::default())));
    let response = ext.route_event(&e, &members).await.unwrap();
    assert_eq!(response["headers"]["location"], "/admin.html");
    assert!(!response.to_string().contains("evil"));
}

#[tokio::test]
async fn a_repeated_sign_in_cookie_header_pair_is_refused_through_the_event() {
    let doc = vectors();
    let request = request_for(&single(&doc, "valid"));
    let pair = request.cookie_pairs[0].clone();
    let mut e = event("GET", "/auth/platform/callback", &request.raw_query);
    e["headers"] = json!({"cookie": format!("{pair}; {pair}")});
    let ext = PlatformSignin::new(vector_handler("alongside", Arc::new(Recorder::default())));
    let response = ext.route_event(&e, &FakeMembers::default()).await.unwrap();
    assert_eq!(response["statusCode"], 400);
}

#[tokio::test]
async fn the_cookie_may_arrive_in_the_cookies_array_of_a_function_url_event() {
    let doc = vectors();
    let request = request_for(&single(&doc, "valid"));
    let mut e = event("GET", "/auth/platform/callback", &request.raw_query);
    e["cookies"] = json!(request.cookie_pairs);
    let members = FakeMembers::resolving(Person::new("person@example.test", Some("Admin")));
    let ext = PlatformSignin::new(vector_handler("alongside", Arc::new(Recorder::default())));
    assert_eq!(ext.route_event(&e, &members).await.unwrap()["statusCode"], 302);
}
