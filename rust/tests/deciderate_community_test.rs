//! Deciderate CROSS-DOMAIN growth, in-process (one Runtime, memory). Proves a
//! domain can drive a command in a SEPARATE bounded context WITHOUT naming it :
//! Invite emits InviteAccepted (its event-out PORT), the HEXAGON
//! (deciderate.hecksagon) wires that event to Community's AddMember command-in
//! PORT via a `driven on` binding, and the Community aggregate (its OWN bluebook,
//! context "Community") grows by one member. Cross-domain communication is the
//! hexagon's job — no policy in the bluebook names another context, no adapter
//! family ; aggregates are ports and the hexagon routes the command through
//! storehouse. The two contexts are merged into one booted runtime exactly as
//! load_combined_domain merges the corpus.

use storehouse::{parser, hecksagon_parser};
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
const HECKSAGON: &str = include_str!("fixtures/deciderate_community.hecksagon");

#[test]
fn accepting_an_invite_grows_the_community_across_contexts() {
    // Merge the two contexts into one domain, mirroring load_combined_domain.
    // Boot WITH the hecksagon : the cross-domain edge is the hexagon's `driven
    // on` binding, NOT a bluebook policy — the bluebook never names Community.
    let mut domain = parser::parse(DECIDERATE);
    let community = parser::parse(COMMUNITY);
    domain.aggregates.extend(community.aggregates);
    domain.policies.extend(community.policies);
    let hex = hecksagon_parser::parse(HECKSAGON);
    let mut rt = Runtime::boot_with_hecksagons(domain, None, vec![hex]);

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
