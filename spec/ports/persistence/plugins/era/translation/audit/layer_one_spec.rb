require "hecks"
require "hecks/ports/persistence/plugins/era"

# M26 (docs/audits/2026-08-10-main-bug-audit.md,
# docs/audits/2026-08-11-bug-triage.md) — Layer 1's lifecycle-value check
# compared a translated record's stored state against `Lifecycle#states`
# (default + every declared TARGET only). A state legitimately declared
# solely as a transition's `from:` — a real, reachable value this era's
# OWN lifecycle names, just never as anyone's target — was never in that
# set, so a perfectly valid record holding it was reported as a violation
# and blocked the mint. `Bluebook::ModelCheck.full_states` is the
# established fix for this exact hole (see its own comment, and
# `fuzzing/properties.rb#lifecycle_values_are_declared`, which already
# uses it for the identical question against a replayed history) — Layer
# 1 must use the same full set, not re-derive a narrower one.
#
# These specs drive `Audit.layer_one!` directly, with a hand-built
# `Bluebook::Lifecycle`/`StateTransition` pair and a minimal aggregate
# double — no bluebook DSL boot needed, same convention as
# layer_two_spec.rb / unfed_report_spec.rb.
RSpec.describe "Layer 1's lifecycle-value check against the full declared state set" do
  # `attribute(_name) => nil` makes `Runtime::Instance` skip both
  # coercion (`Value.hydrate` leaves an unrecognized key's value as-is)
  # and identity materialization (a nil `attribute` short-circuits
  # `materialize_identity!` immediately) — exactly what a bare
  # lifecycle-only fixture needs, without dragging in the rest of the
  # attribute/value-object machinery `Runtime::Instance` otherwise
  # expects a real `Bluebook::Aggregate` to answer.
  unless defined?(FakeAggregate)
    FakeAggregate = Struct.new(:name, :attributes, :lifecycle) do
      def identified_by = nil
      def identity_heads = []
      def attribute(_name) = nil
    end
  end

  # "retired" is declared ONLY as a transition's `from:` — never this
  # lifecycle's default, and never any transition's target — the exact
  # shape `Lifecycle#states` cannot see (it answers default+targets),
  # and `ModelCheck.full_states` can (default+targets+froms).
  def lifecycle_with_from_only_state
    Hecks::Bluebook::Lifecycle.new(
      field:       :status,
      default:     "new",
      transitions: [
        ["Activate", Hecks::Bluebook::StateTransition.new(target: "active", from: "new")],
        ["Archive",  Hecks::Bluebook::StateTransition.new(target: "archived", from: "retired")]
      ]
    )
  end

  def aggregate_with(lifecycle)
    FakeAggregate.new("Widget", [], lifecycle)
  end

  def violations_for(aggregate, after)
    violations = []
    Hecks::Translation::Audit.layer_one!(violations, aggregate, after)
    violations
  end

  it "does not block the mint on a record holding a valid from:-only state" do
    aggregate = aggregate_with(lifecycle_with_from_only_state)
    after = { "w1" => { "status" => "retired" } }

    expect(violations_for(aggregate, after)).to be_empty
  end

  it "still passes a record holding the default or an ordinary target state" do
    aggregate = aggregate_with(lifecycle_with_from_only_state)
    after = {
      "w1" => { "status" => "new" },
      "w2" => { "status" => "active" },
      "w3" => { "status" => "archived" }
    }

    expect(violations_for(aggregate, after)).to be_empty
  end

  it "still catches a state this lifecycle never declares at all" do
    aggregate = aggregate_with(lifecycle_with_from_only_state)
    after = { "w1" => { "status" => "nowhere" } }

    violations = violations_for(aggregate, after)
    expect(violations.size).to eq(1)
    expect(violations.first).to include("Widget#w1")
    expect(violations.first).to include("nowhere")
  end

  it "is a no-op for an aggregate with no lifecycle at all" do
    aggregate = aggregate_with(nil)
    after = { "w1" => { "status" => "anything" } }

    expect(violations_for(aggregate, after)).to be_empty
  end
end
