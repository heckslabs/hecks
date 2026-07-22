//! consequence_tree_tests — the FORWARD lineage traversal (Stage 2)
//!
//! CausationTrace's mirror. Backward is a WALK : an event has at most ONE cause,
//! so each hop is a find() by key and the result is a line. Forward is a TREE :
//! one event may cause MANY, so the traversal fans out over a reverse index
//! (causation_id -> children) and the result has SHAPE, carried as a `depth` on
//! each row (0 = the root event itself).
//!
//! Seeded chains rather than a live saga on purpose — a policy cascade produces
//! one child per event, so it can never exercise the fan-out, the sibling
//! ordering, or the cycle guard that are the whole reason this is a tree and not
//! a walk. The live end-to-end stamping of causation_id is already proven by
//! causation_trace_tests (3) and the correlation proof.

use super::*;

const BLUEBOOK: &str = r#"Hecks.bluebook "Lineage" do
  core
  aggregate "Event" do
    identified_by :event_id
    attribute :event_id, EventId
    attribute :causation_id, CausationId
    value_object "EventId" do
      attribute :value, String
    end
    value_object "CausationId" do
      attribute :value, String
    end
    query "ConsequenceTree" do |event_id|
      description "walk forward from this event through everything it caused"
    end
    query "CausationTrace" do |event_id|
      description "walk the causation chain from this event up to its root cause"
    end
  end
end
"#;

fn ev(id: &str, cause: &str) -> AggregateState {
    let mut s = AggregateState::new(id);
    s.set("event_id", Value::Str(id.to_string()));
    s.set("causation_id", Value::Str(cause.to_string()));
    s
}

fn boot_with(chain: &[(&str, &str)]) -> Runtime {
    let domain = crate::parser::parse(BLUEBOOK);
    let mut rt = Runtime::boot(domain);
    let ctx = rt
        .domain
        .aggregates
        .iter()
        .find(|a| a.name == "Event")
        .and_then(|a| a.context.clone());
    let key = repo_key(ctx.as_deref(), "Event");
    let repo = rt.repositories.get_mut(&key).expect("Event repo present");
    for (id, cause) in chain {
        repo.seed_record(ev(id, cause));
    }
    rt
}

/// (event_id, depth) per row, in the order the traversal returned them.
fn tree(rt: &Runtime, root: &str) -> Vec<(String, i64)> {
    let mut attrs = std::collections::HashMap::new();
    attrs.insert("event_id".to_string(), root.to_string());
    let result = rt.resolve_query("ConsequenceTree", &attrs);
    result
        .get("state")
        .and_then(|s| s.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|e| {
                    let id = e.get("event_id")?.as_str()?.to_string();
                    let depth = e.get("depth")?.as_i64()?;
                    Some((id, depth))
                })
                .collect()
        })
        .unwrap_or_default()
}

#[test]
fn fans_out_to_every_consequence_with_its_depth() {
    // r causes a AND b ; a causes c. The tree from r is every descendant, and
    // the depth reconstructs the shape a flat list would otherwise lose.
    let rt = boot_with(&[("r", ""), ("a", "r"), ("b", "r"), ("c", "a")]);
    assert_eq!(
        tree(&rt, "r"),
        vec![
            ("r".to_string(), 0),
            ("a".to_string(), 1),
            ("b".to_string(), 1),
            ("c".to_string(), 2),
        ],
    );
}

#[test]
fn siblings_come_back_in_a_deterministic_order() {
    // Seeded rows carry no `sequence`, so the tiebreak (event_id) decides — and
    // it must decide the SAME way regardless of the order they were stored in.
    // Repository iteration order is not stable, so without the sort this is the
    // assertion that flakes.
    let forward = boot_with(&[("r", ""), ("a", "r"), ("b", "r"), ("c", "r")]);
    let reversed = boot_with(&[("r", ""), ("c", "r"), ("b", "r"), ("a", "r")]);
    assert_eq!(tree(&forward, "r"), tree(&reversed, "r"));
    assert_eq!(
        tree(&forward, "r").iter().map(|(id, _)| id.as_str()).collect::<Vec<_>>(),
        vec!["r", "a", "b", "c"],
    );
}

#[test]
fn a_leaf_event_caused_nothing() {
    // The tree from a childless event is just itself — the forward mirror of
    // "a root event traces to just itself". Depth is relative to the QUERIED
    // root, so `a` comes back at 0 even though it sits at depth 1 under `r`.
    let rt = boot_with(&[("r", ""), ("a", "r")]);
    assert_eq!(tree(&rt, "a"), vec![("a".to_string(), 0)]);
}

#[test]
fn cycle_is_guarded() {
    // e1 <-> e2 : the fan-out must terminate, visiting each at most once. The
    // backward walk guards this too ; forward needs its own guard because the
    // queue would otherwise re-enqueue forever.
    let rt = boot_with(&[("e1", "e2"), ("e2", "e1")]);
    let rows = tree(&rt, "e1");
    assert_eq!(rows.len(), 2, "each event visited once, got {rows:?}");
    let mut ids: Vec<&str> = rows.iter().map(|(id, _)| id.as_str()).collect();
    ids.sort();
    assert_eq!(ids, vec!["e1", "e2"]);
}

#[test]
fn forward_and_backward_are_mirrors() {
    // The two traversals must agree on the same chain : everything CausationTrace
    // walks up from c must appear in the tree rooted at c's root cause. This is
    // what makes the pair trustable as lineage rather than two unrelated queries.
    let rt = boot_with(&[("r", ""), ("a", "r"), ("c", "a")]);
    let mut back = std::collections::HashMap::new();
    back.insert("event_id".to_string(), "c".to_string());
    let up: Vec<String> = rt
        .resolve_query("CausationTrace", &back)
        .get("state")
        .and_then(|s| s.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|e| e.get("event_id").and_then(|v| v.as_str()).map(String::from))
                .collect()
        })
        .unwrap_or_default();
    assert_eq!(up, vec!["c".to_string(), "a".to_string(), "r".to_string()]);

    let down: Vec<String> = tree(&rt, "r").into_iter().map(|(id, _)| id).collect();
    for id in &up {
        assert!(down.contains(id), "{id} is on the backward walk but missing from the forward tree");
    }
}
