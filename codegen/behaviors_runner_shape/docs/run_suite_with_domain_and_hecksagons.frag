/// Sprint 14 first-adapter slice — hecksagons-aware variant. When
/// `hecksagons` is non-empty, every fresh runtime is built with
/// `Runtime::boot_with_hecksagons` so attached `driven on` adapters
/// can fire on event emission. Falls back to the historical
/// `Runtime::boot` path when the slice is empty so non-conception
/// callers stay byte-identical.
