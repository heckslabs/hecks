use crate::hecksagon_parser;
use crate::world::parser as world_parser;
use super::persistence::persisted_by;

const HECKSAGON: &str = r#"
# The Pizzas hexagon.
Hecks.hecksagon "Pizzas" do
  Pizzas::Pizza.persisted_by("Sqlite")
end
"#;

const WORLD: &str = r#"
# The per-deployment values.
Hecks.world "Pizzas" do
  persisted_by("Sqlite") do
    database "data/pizzas.db"
  end
end
"#;

#[test]
fn the_hecksagon_yields_a_persisted_by_binding() {
    let hexagon = hecksagon_parser::parse(HECKSAGON);

    let binding = hexagon
        .bindings
        .iter()
        .find(|b| b.verb == "persisted_by")
        .unwrap_or_else(|| {
            panic!(
                "no persisted_by binding. bindings={:?} persistence={:?}",
                hexagon
                    .bindings
                    .iter()
                    .map(|b| (b.aggregate.clone(), b.verb.clone(), b.adapter.clone()))
                    .collect::<Vec<_>>(),
                hexagon.persistence
            )
        });

    assert_eq!(binding.aggregate, "Pizzas::Pizza");
    assert_eq!(binding.adapter, "Sqlite");
}

#[test]
fn the_world_yields_the_database_location() {
    let world = world_parser::parse(WORLD);

    let found = world
        .configs
        .iter()
        .find(|config| config.name.to_lowercase() == "sqlite")
        .and_then(|config| config.values.iter().find(|(key, _)| key == "database"))
        .map(|(_, value)| value.clone());

    assert_eq!(
        found,
        Some("data/pizzas.db".to_string()),
        "configs={:?}",
        world
            .configs
            .iter()
            .map(|c| (c.name.clone(), c.values.clone()))
            .collect::<Vec<_>>()
    );
}

#[test]
fn a_second_unmarked_persistence_adapter_is_rejected() {
    let error = persisted_by(
        &[
            ("Pizzas::Pizza".to_string(), "Heki".to_string(), String::new()),
            ("Pizzas::Pizza".to_string(), "Sqlite".to_string(), String::new()),
        ],
        "Pizza",
    )
    .expect_err("two unmarked adapters must be ambiguous");

    assert!(error.contains("2 authoritative persisted_by bindings"));
}

#[test]
fn a_mirror_role_is_rejected_from_persistence() {
    let error = persisted_by(
        &[
            ("Pizzas::Pizza".to_string(), "Heki".to_string(), String::new()),
            ("Pizzas::Pizza".to_string(), "Sqlite".to_string(), "mirror".to_string()),
        ],
        "Pizza",
    )
    .expect_err("mirrors bind through mirrored_by");

    assert!(error.contains("use mirrored_by for replicas"));
}
