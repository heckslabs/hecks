require "spec_helper"

# rust/src/bluebook/projected/registry.rs is bin/ir_rust_registry's output —
# every domain bin/ir_rust has projected, as one table, replacing five spots
# projected/mod.rs used to hand-maintain per domain (a `pub mod` line, a
# match arm each in `by_source`/`by_name`, an entry in `names()`, and a
# second hand-built list inside its own test module).
#
# ALWAYS EVERY DOMAIN — this file's own shape does not depend on which
# Cargo features a particular build enables. Selecting a deployment subset
# (`cargo build --no-default-features --features banking`) is a build flag
# against the `[features]` this generator's own header names in
# rust/Cargo.toml, not a different generated file, so there is exactly one
# checked-in registry.rs to hold fresh here.
#
# Nothing else catches a forgotten regeneration — the Rust build succeeds
# either way, it would just be compiling a stale domain list (or refusing to
# compile at all, if a newly-projected file's module name collides with
# nothing declared here).
RSpec.describe "the projected Rust domain registry" do
  it "rust/src/bluebook/projected/registry.rs matches bin/ir_rust_registry's current output" do
    root       = InMemoryDomain::ROOT
    checked_in = File.read(File.join(root, "rust/src/bluebook/projected/registry.rs"))
    current    = `#{File.join(root, 'bin/ir_rust_registry')}`

    expect(current).not_to be_empty, "bin/ir_rust_registry produced nothing"
    expect(checked_in).to eq(current),
                          "rust/src/bluebook/projected/registry.rs is stale — regenerate with " \
                          "`bin/ir_rust_registry > rust/src/bluebook/projected/registry.rs`"
  end
end
