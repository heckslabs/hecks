//! Causation-tree view — the served dispatch panel's cascade carries lineage
//! and the page ships the tree-render JS.
//!
//! [antibody-exempt: rust/tests/causation_tree_view_test.rs (causation exposure)
//!  — served-UI + causation plumbing, authorized by Chris 2026-07-03]
//!
//! Two guarantees, both socket-free :
//!   (1) `wrap_page` ships the causation-tree JS (cascadeTreeHtml +
//!       highlightCausation) so the wizard renders the cascade as a clickable
//!       tree ;
//!   (2) a real policy cascade through the door (`route` POST /dispatch) returns
//!       cascade JSON where the downstream event's `causation_id` equals the
//!       triggering event's `event_id` — the parent->child link the client
//!       builds the tree from. The root (the originating command's event) carries
//!       an `event_id` and NO `causation_id`. The lineage rides the in-memory
//!       bus, NOT the (gated) durable Log, so no event-sourcing is needed.

use std::cell::RefCell;
use storehouse::parser;
use storehouse::runtime::acl_readmodel::DoorPosture;
use storehouse::runtime::Runtime;
use storehouse::server::{html_shared, route};

// A minimal policy cascade : Trigger.Fire -> Fired -> (policy) -> Target.Land
// -> Landed. Two events, one causal link — enough to prove the tree edge.
const CASCADE_BB: &str = r#"Hecks.bluebook "CausView" do
  core
  aggregate "Trigger" do
    identified_by :name
    attribute :name, Name
    attribute :fired, Fired, default: "no"
    value_object "Name" do
      attribute :value, String
    end
    value_object "Fired" do
      attribute :value, String
    end
    command "Fire" do
      attribute :name, Name
      then_set :fired, to: "yes"
      emits "Fired"
    end
  end
  aggregate "Target" do
    identified_by :name
    attribute :name, Name
    attribute :landed, Landed, default: "no"
    value_object "Name" do
      attribute :value, String
    end
    value_object "Landed" do
      attribute :value, String
    end
    command "Land" do
      attribute :name, Name
      then_set :landed, to: "yes"
      emits "Landed"
    end
  end
  policy "LandOnFired" do
    on "Trigger.Fired"
    trigger "CausView::Target.Land"
    with "name", "t1"
  end
end
"#;

fn booted() -> RefCell<Runtime> {
    let domain = parser::parse(CASCADE_BB);
    RefCell::new(Runtime::boot(domain))
}

// ── (1) the served page ships the tree-render JS ──

#[test]
fn served_page_ships_causation_tree_js() {
    let page = html_shared::wrap_page("Demo", "", "");
    assert!(page.contains("cascadeTreeHtml"), "wizard must ship the tree builder");
    assert!(
        page.contains("highlightCausation"),
        "wizard must ship the click-to-highlight handler"
    );
    assert!(page.contains("causation tree"), "the tree render must label the panel");
    assert!(
        page.contains("data-cid="),
        "tree nodes must carry their causation link for parent/child highlighting"
    );
}

// ── (2) a door cascade carries the parent->child lineage the tree keys on ──

#[test]
fn door_cascade_json_carries_parent_child_lineage() {
    let rt = booted();
    let body = r#"{"command": "CausView::Trigger.Fire", "attrs": {"name": "t1"}}"#;
    let (status, resp) = route("POST", "/dispatch", body, None, DoorPosture::Open, &rt);
    assert_eq!(status, "200 OK", "fire must dispatch: {}", resp);

    let v: serde_json::Value = serde_json::from_str(&resp).expect("cascade JSON parses");
    let cascade = v["cascade"].as_array().expect("cascade array present");

    let fired = cascade
        .iter()
        .find(|e| e["event"] == "Fired")
        .unwrap_or_else(|| panic!("Fired in cascade: {}", resp));
    let landed = cascade
        .iter()
        .find(|e| e["event"] == "Landed")
        .unwrap_or_else(|| panic!("Landed (cascaded) in cascade: {}", resp));

    // Root : the originating command's event carries an event_id and NO cause.
    let fired_id = fired["event_id"].as_str().expect("Fired carries an event_id");
    assert!(!fired_id.is_empty(), "root event_id is non-empty: {}", resp);
    assert!(
        fired["causation_id"].is_null(),
        "root Fired has no causation_id (it is the tree root): {}",
        resp
    );

    // Child : the cascaded event's causation_id == the triggering event's id.
    assert_eq!(
        landed["causation_id"].as_str(),
        Some(fired_id),
        "Landed must cite Fired as its cause (the tree edge): {}",
        resp
    );
    // And the child carries its own distinct id (a further cascade could cite it).
    let landed_id = landed["event_id"].as_str().expect("Landed carries an event_id");
    assert_ne!(landed_id, fired_id, "each event has a distinct event_id: {}", resp);
}
