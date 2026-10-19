//! The wall clock, read once the same way everywhere.

/// Whole seconds since the Unix epoch; 0 if the system clock reads before it.
pub(crate) fn unix_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs() as i64)
}
