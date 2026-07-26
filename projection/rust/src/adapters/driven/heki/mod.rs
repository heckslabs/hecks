//! heki - the append-log persistence adapter, cherry-picked from Hecks unedited.
//! Mirrors adapters/driven/ on the Ruby side ; the file keeps its Hecks name and
//! contents, and only the folder moved.

#[allow(dead_code)]
mod heki;
pub use heki::*;

mod repository;
pub use repository::HekiRepository;
