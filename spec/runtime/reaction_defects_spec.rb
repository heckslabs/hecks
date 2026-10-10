require "spec_helper"

# A domain refusal is recorded and the emitting command stands; a runtime defect is
# recorded distinguishably (`defect: true`, error class) and warned to STDERR.
RSpec.describe "a reaction that cannot be delivered" do
  let(:event) do
    Hecks::Runtime::Event.new(
      name: "Rang", aggregate: "Reflex::Echo", id: "bell-1",
      payload: {}, occurred_at: Time.now.utc.iso8601
    )
  end

  let(:policy) do
    Hecks::Bluebook::Policy.new(
      name: "ReactToRing", on_event: "Rang", trigger_command: "Echo.Ring"
    )
  end

  let(:registry) { registry_for(policy) }

  # A dispatcher that fails the way the thing behind it fails.
  def dispatcher_raising(error)
    Class.new do
      define_method(:reaction_depth_reached?) { false }
      define_method(:max_reaction_depth) { 8 }
      define_method(:reenter) { |*, **| raise error }
    end.new
  end

  # `#aggregate` answers nil like a real Bluebook asked about an unloaded target;
  # ReactionInvocation#resolve_target reads it before the dispatcher, so a double
  # without it would raise its own NoMethodError.
  def bluebook_double(policy)
    Class.new do
      attr_reader :name, :policies

      define_method(:initialize) do |name, policies|
        @name = name
        @policies = policies
      end
      define_method(:aggregate) { |_name| nil }
    end.new("Reflex", [policy])
  end

  def registry_for(policy)
    bluebook = bluebook_double(policy)

    Class.new do
      attr_reader :reaction_log

      define_method(:initialize) { @reaction_log = [] }
      define_method(:log_reaction) { |record, **| @reaction_log << record }
      define_method(:bluebook) { |_domain| bluebook }
      define_method(:bluebooks) { { "Reflex" => bluebook } }
    end.new
  end

  def interpreter_failing_with(error)
    Hecks::Runtime::PolicyInterpreter.new(registry, dispatcher: dispatcher_raising(error))
  end

  it "RECORDS a refusal by the domain — the emitting command still stands", :aggregate_failures do
    interpreter = interpreter_failing_with(Hecks::Runtime::GivenNotMet.new("bell already rung"))

    expect { interpreter.react(event, "Reflex") }.not_to raise_error
    expect(registry.reaction_log.first).to include(delivered: false, reason: "bell already rung")
  end

  it "RECORDS a defect in the runtime, distinguishably, rather than raising or logging it as a refusal",
     :aggregate_failures do
    interpreter = interpreter_failing_with(NoMethodError.new("undefined method `boom'"))

    expect { interpreter.react(event, "Reflex") }.to output(/ReactToRing.*Rang.*boom/m).to_stderr
    expect(registry.reaction_log.first).to include(
      delivered: false, reason: "undefined method `boom'", defect: true, error_class: "NoMethodError"
    )
  end
end
