//! P0.1 — the list-remove mutation op (`then_set :field, remove: :x`).
//!
//! Inverse of `append:`. Carries ONLY the element ; the runtime drops every
//! matching entry from the list element-wise (no read-modify-write, so a
//! concurrent append can't be lost). Proves the parse + IR + runtime apply.

use storehouse::parser;
use storehouse::runtime::{Runtime, Value};
use std::collections::HashMap;

fn s(v: &str) -> Value { Value::Str(v.to_string()) }
fn attrs(p: &[(&str, Value)]) -> HashMap<String, Value> {
    p.iter().map(|(k, v)| (k.to_string(), v.clone())).collect()
}

const SRC: &str = r#"Hecks.bluebook "Tagged" do
  aggregate "Item" do
    identified_by :id
    attribute :id, String
    attribute :tags, list_of(String)
    command "Create" do
      attribute :id, String
      emits "Created"
    end
    command "AddTag" do
      reference_to(Item)
      attribute :tag, String
      then_set :tags, append: :tag
      emits "TagAdded"
    end
    command "RemoveTag" do
      reference_to(Item)
      attribute :tag, String
      then_set :tags, remove: :tag
      emits "TagRemoved"
    end
  end
end
"#;

fn tags(rt: &Runtime, id: &str) -> Vec<String> {
    rt.all_qualified(Some("Tagged"), "Item")
        .into_iter()
        .find(|r| r.id == id)
        .and_then(|r| r.fields.get("tags").cloned())
        .map(|v| match v {
            Value::List(items) => items.iter().map(|x| x.to_string()).collect(),
            _ => vec![],
        })
        .unwrap_or_default()
}

#[test]
fn remove_drops_matching_list_elements() {
    let domain = parser::parse(SRC);
    let mut rt = Runtime::boot(domain);

    rt.dispatch("Tagged::Item.Create", attrs(&[("id", s("i1"))])).unwrap();
    rt.dispatch("Tagged::Item.AddTag", attrs(&[("id", s("i1")), ("tag", s("a"))])).unwrap();
    rt.dispatch("Tagged::Item.AddTag", attrs(&[("id", s("i1")), ("tag", s("b"))])).unwrap();
    rt.dispatch("Tagged::Item.AddTag", attrs(&[("id", s("i1")), ("tag", s("a"))])).unwrap();
    assert_eq!(tags(&rt, "i1"), vec!["a", "b", "a"], "appended");

    // Remove drops EVERY matching element, element-wise.
    rt.dispatch("Tagged::Item.RemoveTag", attrs(&[("id", s("i1")), ("tag", s("a"))])).unwrap();
    assert_eq!(tags(&rt, "i1"), vec!["b"], "both 'a' dropped, 'b' kept");

    // Removing an absent element is a no-op (no read-modify-write needed).
    rt.dispatch("Tagged::Item.RemoveTag", attrs(&[("id", s("i1")), ("tag", s("zzz"))])).unwrap();
    assert_eq!(tags(&rt, "i1"), vec!["b"], "absent remove is a no-op");
}
