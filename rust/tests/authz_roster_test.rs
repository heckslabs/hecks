//! authz_roster_test.rs — Phase 4 : authz decoupled from Agent + the roster.
//!
//! Proves, against the REAL authorization.bluebook (include_str! — the shipped
//! roster, not a test replica), that :
//!   1. the `on "BootCompleted"` roster policies self-seed RoleAssignment +
//!      Policy records at boot (the keystone firing the authz context) ;
//!   2. the RBAC read-model hydrates auth_identity_id -> role_name from
//!      RoleAssignment — NOT from Agent, which carries no auth surface —
//!      including after the roster's CASCADE-authored writes (the post-settle
//!      re-hydrate in complete_over) ;
//!   3. the four-case verdicts hold at the entry door : System admitted by
//!      origin ; ghost denied (deny-by-default) ; pr-agent admitted on
//!      Tools::* ; pr-agent forbidden on Authorization::* ;
//!   4. role-grouping is real : sidequest shares the workflow-subagent role
//!      and is admitted through that role's permit ;
//!   5. the roster is idempotent : a second BootCompleted re-asserts without
//!      duplicating (upsert on natural keys).
//!
//! [antibody-exempt: rust/tests/authz_roster_test.rs — kernel-surface
//!  integration test for the Phase 4 authz decouple. Asserts on Rust runtime
//!  state + gate verdicts, so it is necessarily Rust. Same category as
//!  boot_completion_test.rs.]

use std::collections::HashMap;
use storehouse::parser;
use storehouse::run_boot::complete::complete_over;
use storehouse::runtime::Value;

/// The REAL authorization context — Policy + RoleAssignment + the roster.
const AUTHZ: &str = include_str!(
    "../../hecks_conception/aggregates/framework/authorization/authorization.bluebook"
);

// A minimal boot domain : the sole thing that matters is `CompleteBoot`
// emits `BootCompleted` (mirrors boot_completion_test.rs).
const BOOT: &str = r#"Hecks.bluebook "Boot" do
  aggregate "BootRun" do
    attribute :phase, String, default: "pending"
    command "CompleteBoot" do
      role "System"
      emits "BootCompleted"
    end
  end
end"#;

// A tiny Tools-context command so the roster's `Tools::*` permit has a real
// action to admit. The context name is what the prefix-glob matches.
const TOOLS: &str = r#"Hecks.bluebook "Tools" do
  aggregate "Widget" do
    attribute :touched, String, default: "false"
    command "Touch" do
      role "System"
      then_set :touched, to: "true"
      emits "Touched"
    end
  end
end"#;

/// Reserved principal meta-attr keys — the door-stamp contract
/// (acl_readmodel::KIND_KEY / AUTH_KEY).
const KIND_KEY: &str = "actor_kind";
const AUTH_KEY: &str = "actor_auth_id";

fn corpus() -> storehouse::ir::Domain {
    let mut corpus = parser::parse(AUTHZ);
    let tools = parser::parse(TOOLS);
    corpus.aggregates.extend(tools.aggregates);
    corpus
}

fn stamped(auth_id: &str) -> HashMap<String, Value> {
    let mut attrs = HashMap::new();
    attrs.insert(KIND_KEY.to_string(), Value::Str("agent".to_string()));
    attrs.insert(AUTH_KEY.to_string(), Value::Str(auth_id.to_string()));
    attrs
}

/// The roster establishes at boot : assignments + grants exist, and the
/// read-model resolves roles from RoleAssignment state — including the
/// cascade-authored records the entry-dispatch trigger cannot see (proves
/// the post-settle re-hydrate).
#[test]
fn roster_establishes_and_readmodel_resolves() {
    let rt = complete_over(parser::parse(BOOT), corpus(), None, vec![], None, "Miette");

    // Assignments : three identities, two roles (sidequest shares).
    assert_eq!(rt.all("RoleAssignment").len(), 3, "roster must assign 3 identities");
    assert_eq!(rt.acl_read_model.role_for_auth("pr-agent"), Some("pr-agent"));
    assert_eq!(rt.acl_read_model.role_for_auth("workflow-subagent"), Some("workflow-subagent"));
    assert_eq!(
        rt.acl_read_model.role_for_auth("sidequest"),
        Some("workflow-subagent"),
        "role-grouping : two identities share one role"
    );
    assert_eq!(rt.acl_read_model.role_for_auth("ghost"), None, "unrostered resolves to no role");

    // Grants : the six roster rules, active.
    let policies = rt.all("Policy");
    for id in [
        "roster-pr-agent-tools",
        "roster-pr-agent-no-authz",
        "roster-pr-agent-no-governance",
        "roster-workflow-subagent-tools",
        "roster-workflow-subagent-no-authz",
        "roster-workflow-subagent-no-governance",
    ] {
        assert!(
            policies.iter().any(|st| {
                matches!(st.get("id"), Value::Str(s) if s == id)
                    && matches!(st.get("status"), Value::Str(s) if s == "active")
            }),
            "roster grant '{}' must exist and be active",
            id
        );
    }
}

/// The four-case at the entry door, plus the role-grouping admit.
#[test]
fn four_case_verdicts_at_the_door() {
    let mut rt = complete_over(parser::parse(BOOT), corpus(), None, vec![], None, "Miette");

    // 1. System (unstamped) : admitted by origin.
    assert!(
        rt.dispatch("Tools::Widget.Touch", HashMap::new()).is_ok(),
        "System origin must be admitted"
    );

    // 2. Ghost agent : deny-by-default (no assignment, no permit).
    assert!(
        rt.dispatch("Tools::Widget.Touch", stamped("ghost")).is_err(),
        "unrostered agent must be denied by default"
    );

    // 3. pr-agent on Tools::* : admitted through its role's permit.
    assert!(
        rt.dispatch("Tools::Widget.Touch", stamped("pr-agent")).is_ok(),
        "pr-agent must be admitted on Tools::*"
    );

    // 4. pr-agent on Authorization::* : forbidden (forbid overrides permit).
    let mut assign = stamped("pr-agent");
    assign.insert("auth_identity_id".to_string(), Value::Str("intruder".to_string()));
    assign.insert("role_name".to_string(), Value::Str("admin".to_string()));
    assert!(
        rt.dispatch("Authorization::RoleAssignment.Assign", assign).is_err(),
        "pr-agent must be forbidden on Authorization::*"
    );
    assert_eq!(
        rt.acl_read_model.role_for_auth("intruder"),
        None,
        "the forbidden Assign must not have applied"
    );

    // 5. Role-grouping : sidequest is admitted through the SHARED
    //    workflow-subagent role's permit.
    assert!(
        rt.dispatch("Tools::Widget.Touch", stamped("sidequest")).is_ok(),
        "sidequest must be admitted through the shared workflow-subagent role"
    );
}

/// Idempotency : a second BootCompleted re-asserts the roster without
/// duplicating — every target upserts on its natural key.
#[test]
fn roster_reassertion_is_idempotent() {
    let mut rt = complete_over(parser::parse(BOOT), corpus(), None, vec![], None, "Miette");
    let _ = rt.dispatch("BootRun.CompleteBoot", HashMap::new());

    assert_eq!(rt.all("RoleAssignment").len(), 3, "re-boot must not duplicate assignments");
    let roster_rules = rt
        .all("Policy")
        .iter()
        .filter(|st| matches!(st.get("id"), Value::Str(s) if s.starts_with("roster-")))
        .count();
    assert_eq!(roster_rules, 6, "re-boot must not duplicate grants");
    assert_eq!(rt.acl_read_model.role_for_auth("pr-agent"), Some("pr-agent"));
}
