//! Deciderate CROSS-CONTEXT growth, in-process (one Runtime, memory). Proves a
//! policy in the Deciderate context can drive a command in a SEPARATE bounded
//! context : accepting an Invite (Deciderate) fires GrowCommunityOnAccept,
//! whose trigger is the context-qualified FQN `Community::Community.AddMember`,
//! and the Community aggregate (its OWN bluebook, context "Community") grows by
//! one member. The two contexts are merged into one booted runtime exactly as
//! load_combined_domain merges the corpus ; the resolver picks AddMember by its
//! context qualifier.

use storehouse::parser;
use storehouse::runtime::{Runtime, Value};
use std::collections::HashMap;

fn s(v: &str) -> Value { Value::Str(v.to_string()) }
fn a(p: &[(&str, &str)]) -> HashMap<String, Value> {
    p.iter().map(|(k, v)| (k.to_string(), s(v))).collect()
}
fn field(rt: &Runtime, agg: &str, id: &str, f: &str) -> String {
    rt.find(agg, id).and_then(|st| st.fields.get(f).map(|v| v.to_string())).unwrap_or_default()
}

const DECIDERATE: &str = include_str!("fixtures/deciderate_invite.bluebook");
const COMMUNITY: &str = include_str!("fixtures/deciderate_community.bluebook");

#[test]
fn accepting_an_invite_grows_the_community_across_contexts() {
    // Merge the two contexts into one domain, mirroring load_combined_domain.
    let mut domain = parser::parse(DECIDERATE);
    let community = parser::parse(COMMUNITY);
    domain.aggregates.extend(community.aggregates);
    domain.policies.extend(community.policies);
    let mut rt = Runtime::boot_with_hecksagons(domain, None, vec![]);

    rt.dispatch("Found", a(&[("id", "comm1")])).unwrap();
    assert_eq!(field(&rt, "Community", "comm1", "member_count"), "0", "fresh community");

    rt.dispatch("Create", a(&[("id", "inv1"), ("community", "comm1"), ("player", "p1")])).unwrap();
    // Accepting the invite (Deciderate) must grow comm1 (Community) by one
    // member, purely via the cross-context policy GrowCommunityOnAccept.
    rt.dispatch("Accept", a(&[("invite", "inv1"), ("community", "comm1"), ("player", "p1")])).unwrap();
    assert_eq!(field(&rt, "Invite", "inv1", "status"), "accepted", "invite accepted");
    assert_eq!(
        field(&rt, "Community", "comm1", "member_count"), "1",
        "the cross-context policy must have grown the community by one member",
    );
}
