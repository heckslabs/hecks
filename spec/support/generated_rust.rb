require "rspec/core"

# Specs that read the generated Rust tree (`rust/src/generated/<domain>/`), which is not committed:
# a fresh checkout has only `mod.rs` and `pizzas/`. Without the rest they fail on a bare
# `expected [] to include "payments"`, so each such group says what to run instead.
RSpec.shared_context "with the generated Rust tree" do
  GENERATED_RUST_REMEDY = "run `HECKS_ENVIRONMENT=memory exe/hecks regeneration_run.regenerate_corpus! " \
                          "--confirm --wait` first: rust/src/generated holds only what a fresh checkout " \
                          "carries, and these examples read the rest".freeze

  before(:all) do
    root      = File.expand_path("../../rust/src/generated", __dir__)
    generated = Dir.children(root).select { |name| File.exist?(File.join(root, name, "ir.json")) }
    raise GENERATED_RUST_REMEDY if generated.size < 2
  end
end
