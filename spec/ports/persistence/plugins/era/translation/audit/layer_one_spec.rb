require "hecks"
require "hecks/ports/persistence/plugins/era"

# Layer 1 must accept a state declared only as a transition's `from:`, so it checks against
# `ModelCheck.full_states` rather than `Lifecycle#states`. Drives `Audit.layer_one!` directly.
RSpec.describe "Layer 1's lifecycle-value check against the full declared state set" do
  # `attribute(_name) => nil` makes `Runtime::Instance` skip coercion and identity
  # materialization, which a bare lifecycle-only fixture does not need.
  unless defined?(FakeAggregate)
    FakeAggregate = Struct.new(:name, :attributes, :lifecycle) do
      def identified_by = nil
      def identity_heads = []
      def attribute(_name) = nil
    end
  end

  # "retired" appears only as a `from:`, which `Lifecycle#states` misses and `full_states` sees.
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
