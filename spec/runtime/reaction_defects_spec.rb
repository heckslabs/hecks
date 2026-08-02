require "spec_helper"

# A reaction has two ways to not happen, and they are not the same thing.
#
# The domain REFUSING (a given not met, a lifecycle move not admitted, a
# cross-domain target not loaded in this deployment) is a fact worth recording :
# the command that emitted the event still stands, and the log says why.
#
# The runtime BREAKING (a NoMethodError in an interpreter, a NameError from a
# missing constant) is a defect. It used to land in the same place, via a
# blanket `rescue StandardError`, and be written as `delivered: false` beside
# every legitimate refusal — so a crashed runtime read as normal operation.
RSpec.describe "a reaction that cannot be delivered" do
  let(:event) do
    Hecksagain::Runtime::Event.new(
      name: "Rang", aggregate: "Reflex::Echo", id: "bell-1",
      payload: {}, occurred_at: Time.now.utc.iso8601
    )
  end

  let(:policy) do
    Hecksagain::Bluebook::IR::Policy.new(
      name: "ReactToRing", on_event: "Rang", trigger_command: "Echo.Ring"
    )
  end

  # A door that fails the way the thing behind it fails.
  def door_raising(error)
    Class.new do
      define_method(:reaction_depth_reached?) { false }
      define_method(:max_reaction_depth) { 8 }
      define_method(:reenter) { |*, **| raise error }
    end.new
  end

  def registry_for(policy)
    bluebook = Struct.new(:policies).new([policy])
    Class.new do
      attr_reader :reaction_log
      define_method(:initialize) { @reaction_log = [] }
      define_method(:bluebook) { |_domain| bluebook }
    end.new
  end

  it "RECORDS a refusal by the domain — the emitting command still stands" do
    registry = registry_for(policy)
    interpreter = Hecksagain::Runtime::PolicyInterpreter.new(
      registry, door: door_raising(Hecksagain::Runtime::GivenNotMet.new("bell already rung"))
    )

    expect { interpreter.react(event, "Reflex") }.not_to raise_error
    expect(registry.reaction_log.first).to include(delivered: false, reason: "bell already rung")
  end

  it "RAISES a defect in the runtime rather than logging it as an undelivered reaction" do
    registry = registry_for(policy)
    interpreter = Hecksagain::Runtime::PolicyInterpreter.new(
      registry, door: door_raising(NoMethodError.new("undefined method `boom'"))
    )

    expect { interpreter.react(event, "Reflex") }.to raise_error(NoMethodError, /boom/)
    expect(registry.reaction_log).to be_empty
  end
end
