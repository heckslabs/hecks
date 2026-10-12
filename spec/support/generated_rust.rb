require "rspec/core"

# Specs that read the generated Rust tree (`rust/src/generated/<domain>/`), which is not committed:
# a fresh checkout has only `mod.rs` and `pizzas/`.
#
# Without the rest, a local run skips each such group and says what to run to include it, so a
# bare checkout is green. CI and the full push gate (`HECKS_PRE_PUSH_GATE=1`) fail instead: they
# materialize the tree first, so a missing one there is a broken step, not a reason to skip.
RSpec.shared_context "with the generated Rust tree" do
  GENERATED_RUST_REMEDY = "run `HECKS_ENVIRONMENT=memory exe/hecks regeneration_run.regenerate_corpus! " \
                          "--confirm --wait` first: rust/src/generated holds only what a fresh checkout " \
                          "carries, and these examples read the rest".freeze

  before(:all) do
    root      = File.expand_path("../../rust/src/generated", __dir__)
    generated = Dir.children(root).select { |name| File.exist?(File.join(root, name, "ir.json")) }
    next unless generated.size < 2

    strict = ENV.fetch("CI", "").casecmp("true").zero? || !ENV.fetch("HECKS_PRE_PUSH_GATE", "").empty?
    raise GENERATED_RUST_REMEDY if strict

    skip GENERATED_RUST_REMEDY
  end
end
