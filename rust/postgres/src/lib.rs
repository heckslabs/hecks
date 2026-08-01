mod postgres_repository;

pub use postgres_repository::{postgres_factory, register, PostgresRepository};

/// The storage-shape projection of one bluebook source — parse with the
/// core parser, project with the core projection. Shared by the era
/// gate so held texts compare structurally, never by bytes or hashes.
pub fn shape_of(source: &str) -> serde_json::Value {
    storehouse::runtime::storage_shape::project(&storehouse::parser::parse(source))
}
