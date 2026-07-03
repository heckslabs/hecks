//! Served-UI bearer + governance-denial surface.
//!
//! Three guarantees, all socket-free :
//!   (1) the generated app shell carries the Bearer token control
//!       (localStorage 'hecks_bearer') and every dispatch fetch routes its
//!       headers through authHeaders() — `Authorization: Bearer <token>`
//!       attaches whenever the token is non-empty ;
//!   (2) the standalone Living Diagram page carries the same JS ;
//!   (3) a 403 from `routes::route` carries exactly the JSON the JS
//!       renders verbatim in the governance banner :
//!       {"ok":false,"error":"GOVERNANCE …","command":…}.
//!
//! NOTE : the Event Stream panel is client-side only (populated by
//! addEvent() from dispatch responses) — there is no EventSource/SSE
//! fetch in the served UI, so no bearer needs to ride an event stream.

use std::cell::RefCell;
use storehouse::parser;
use storehouse::runtime::acl_readmodel::DoorPosture;
use storehouse::runtime::Runtime;
use storehouse::server::{html_diagram, html_shared, route};

const AUTHZ: &str =
    include_str!("../../hecks_conception/aggregates/framework/authorization/authorization.bluebook");
const DEMO: &str = include_str!("fixtures/authz_demo.bluebook");

/// Env hygiene — same recipe as http_door_gate_test : never let the ambient
/// deploy-floor or a session identity leak into a posture test.
fn scrub_env() {
    std::env::remove_var("HECKS_GOVERNANCE_OFF");
    std::env::remove_var("HECKS_SESSION_AUTH_ID");
    std::env::remove_var("HECKS_PRINCIPAL_KIND");
}

fn booted() -> RefCell<Runtime> {
    scrub_env();
    let mut domain = parser::parse(AUTHZ);
    domain.aggregates.extend(parser::parse(DEMO).aggregates);
    RefCell::new(Runtime::boot_with_hecksagons(domain, None, vec![]))
}

// ── (1) app shell : token control + header-attach JS + denial banner ──

#[test]
fn app_shell_carries_bearer_input_and_header_attach_js() {
    let page = html_shared::wrap_page("Demo", "", "");
    // The compact token control in the top-bar chrome.
    assert!(page.contains(r#"id="bearer-token""#), "top bar must carry the Bearer input");
    assert!(page.contains("hecks_bearer"), "token must persist under localStorage 'hecks_bearer'");
    // The header-attach helper + its use on the dispatch fetches.
    assert!(page.contains("'Bearer ' + t"), "authHeaders must attach Authorization: Bearer <token>");
    assert!(
        page.contains("authHeaders({'Content-Type': 'application/json'})"),
        "submitCmd/wizardSubmit fetches must route headers through authHeaders"
    );
    // The unmissable denial rendering.
    assert!(page.contains("governance-banner"), "denial banner renderer must be present");
    assert!(page.contains("showDenial("), "dispatch error paths must raise the denial banner");
    assert!(
        page.contains("isGovernanceDenial(resp.status, r)"),
        "403 / GOVERNANCE-text detection must gate the banner"
    );
}

// ── (2) the standalone Living Diagram page carries the same JS ──

#[test]
fn diagram_page_carries_bearer_and_denial_js() {
    let rt = booted();
    let page = html_diagram::generate("AuthzDemo", &rt);
    assert!(page.contains("'Bearer ' + t"), "diagram dispatch must attach the bearer header");
    assert!(page.contains("authHeaders("), "diagram fetch must route headers through authHeaders");
    assert!(page.contains("governance-banner"), "diagram page must render denials in the banner");
}

// ── (3) a door 403 carries the JSON shape the JS renders verbatim ──

#[test]
fn door_403_carries_the_json_the_ui_renders() {
    let rt = booted();
    let body = r#"{"command": "Open", "attrs": {"name": "vX"}}"#;
    let (status, resp) = route("POST", "/dispatch", body, None, DoorPosture::Governed, &rt);
    assert_eq!(status, "403 Forbidden", "unstamped dispatch under governed must 403: {}", resp);
    assert!(resp.contains(r#""ok":false"#), "JS branches on r.ok: {}", resp);
    assert!(resp.contains(r#""error":"#), "JS renders r.error verbatim in the banner: {}", resp);
    assert!(resp.contains(r#""command":"#), "the denied verb rides the body: {}", resp);
}
