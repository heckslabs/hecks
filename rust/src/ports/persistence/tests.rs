
use crate::hecksagon_parser;
use crate::world::parser as world_parser;

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
        world.configs.iter().map(|c| (c.name.clone(), c.values.clone())).collect::<Vec<_>>()
    );
}
