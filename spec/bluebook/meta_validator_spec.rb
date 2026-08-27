require "spec_helper"
require "digest"
require "json"

# H9 — the meta-validator's verdict cache (`MetaValidator.verdicts`) is a
# single MODULE-LEVEL hash, shared across every registry a process ever
# builds, keyed on `SHA256(JSON(bluebook.to_h))` (meta_validator.rb#call).
# Before `ReadModel#to_h` grew `wheres`/`order_by`/`limit` (2026-08-11),
# two chapters differing ONLY in a read-model's filter hashed identically,
# so booting chapter A with `where status: "available"`, then — in the
# same process, e.g. a test suite, a console, hecks_studio — booting an
# otherwise-identical chapter of the SAME NAME with the filter edited to
# `"retired"`, handed the second boot the FIRST boot's already-assembled,
# stale read model.
#
# `ReadModel#to_h`'s own fix already retired the underlying cause; these
# are the regression lock for the meta-validator's own cache key, so a
# future field this codebase adds to a read model (or to a bluebook) that
# forgets to reach `to_h` fails HERE rather than silently reintroducing
# the class of bug.
RSpec.describe "MetaValidator's verdict cache" do
  def in_registry
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      yield
    end
    registry
  end

  # A single-aggregate, rootless read model (no `reference_to`, just an
  # `include`) filtered by a lifecycle field — the same minimal shape
  # `spec/dsl_spec.rb`'s own read-model tests already use, so a genuinely
  # DSL-built, MetaValidator-judged chapter, not a hand-rolled IR object.
  def build_catalog(name, filter_value)
    in_registry do
      Hecks.bluebook(name) do
        aggregate "Widget" do
          identified_by :id
          lifecycle :status, default: "available" do
            transition "Retire" => "retired", from: "available"
          end
        end

        read_model "Catalog" do
          include Widget

          where(status: filter_value)
        end
      end
    end.bluebook(name)
  end

  it "does not serve a stale read-model filter after a same-process reload with only the filter edited" do
    first  = build_catalog("StaleFilterCheck", "available")
    second = build_catalog("StaleFilterCheck", "retired")

    expect(first.read_models.first.wheres.first.value).to eq("available")
    expect(second.read_models.first.wheres.first.value).to eq("retired")
  end

  it "the cache key hashes a read-model filter, so editing only the filter changes the key" do
    key_for = lambda do |filter_value|
      Digest::SHA256.hexdigest(JSON.generate(build_catalog("KeyCheck", filter_value).to_h))
    end

    expect(key_for.call("available")).not_to eq(key_for.call("retired"))
  end
end
