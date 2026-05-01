/// Fixture-aware variant. When `fixtures` is `Some`, every fresh
/// runtime is seeded with those records BEFORE setups run (i4 gap 8).
/// When `None`, behaves exactly like `run_suite` — pass-through.
