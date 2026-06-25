/// One declared process_manager. Mirrors
/// `Hecks::BluebookModel::Behavior::ProcessManager` minus the action proc
/// (which is Ruby-side execution and not part of the static shape).
/// Parity contract : this struct round-trips byte-identically through
/// canonical_ir.rb / dump.rs.
