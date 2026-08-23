require "spec_helper"

RSpec.describe "policy and process lexical visibility" do
  def boot_visibility_reaction
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)

      Hecks.bluebook "ReactionVisibility" do
        aggregate "Meter" do
          value_object("Code") { attribute :value, String }
          value_object("Reading") { attribute :value, Integer }

          attribute :code, Code
          attribute :reading, Reading
          identified_by :code

          given("the proposed reading is higher than current parent state") do
            parent.reading.value < reading.value
          end

          command "Install" do
            attribute :code, Code
            attribute :reading, Reading
            sets :code
            sets :reading
            emits "MeterInstalled"
          end

          command "RaiseReading" do
            reference_to Meter
            attribute :reading, Reading
            given("the proposed reading is higher than current parent state")
            sets :reading
            emits "ReadingRaised"
          end

          command "ProposeRaise" do
            reference_to Meter
            attribute :reading, Reading
            emits "RaiseProposed"
          end

          command "Observe" do
            reference_to Meter
            emits "MeterObserved"
          end

          command "Touch" do
            reference_to Meter
            emits "MeterTouched"
          end
        end

        aggregate "Proposal" do
          value_object("Reference") { attribute :value, String }
          value_object("Reading") { attribute :value, Integer }

          attribute :reference, Reference
          attribute :reading, Reading
          attribute :claimed_parent_reading, Reading
          identified_by :reference
          reference_to Meter, as: :meter

          command "Report" do
            attribute :reference, Reference
            reference_to Meter, as: :meter
            attribute :reading, Reading
            attribute :claimed_parent_reading, Reading
            sets :reference
            sets :meter
            sets :reading
            sets :claimed_parent_reading
            emits "ProposalReported"
          end
        end

        policy "ApplyProposal" do
          on "ProposalReported"
          trigger Meter::RaiseReading, with: { meter: :meter, reading: :reading }
        end

        policy "ApplyOwnProposal" do
          on "RaiseProposed"
          trigger Meter::RaiseReading, with: { reading: :reading }
        end

        policy "TouchOnObservation" do
          on "MeterObserved"
          trigger Meter::Touch
        end
      end
    end

    registry.verify!
    Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
  end

  def recording_door
    Class.new do
      attr_reader :calls

      def initialize = @calls = []
      def reenter(verb, **arguments) = @calls << [verb, arguments]
      def reaction_depth_reached? = false
      def max_reaction_depth = 16
    end.new
  end

  it "routes identity, maps event facts, and leaves target parent state lexical" do
    runtime = boot_visibility_reaction
    runtime.dispatch(
      "ReactionVisibility::Meter.Install",
      with: { code: { value: "meter-1" }, reading: { value: 10 } }
    )
    calls = []
    real_reenter = runtime.method(:reenter)
    runtime.define_singleton_method(:reenter) do |verb, **arguments|
      calls << [verb, arguments]
      real_reenter.call(verb, **arguments)
    end

    runtime.dispatch(
      "ReactionVisibility::Proposal.Report",
      with: {
        reference:              { value: "proposal-1" },
        meter:                  "meter-1",
        reading:                { value: 12 },
        claimed_parent_reading: { value: 999 }
      }
    )

    expect(calls).to include([
                               "ReactionVisibility::Meter.RaiseReading",
                               { to: "meter-1", with: { reading: { value: 12 } } }
                             ])
    expect(ReactionVisibility::Meter.find("meter-1").reading.to_h).to eq(value: 12)
  end

  it "resolves process mappings through current event, opening memory, then explicit correlation" do
    resolved = Hecksagain::Runtime::ReactionInvocation.resolve_mapping(
      with_spec: {
        current:     :amount,
        remembered:  :destination,
        correlation: :reference
      },
      scopes:    [
        ["current event payload", { amount: { cents: 20 } }],
        ["opening event memory", { amount: { cents: 10 }, destination: "account-2" }]
      ],
      bindings:  { reference: "transfer-1" },
      label:     "Settlement's dispatch"
    )

    expect(resolved).to eq(
      current:     { cents: 20 },
      remembered:  "account-2",
      correlation: "transfer-1"
    )
  end

  it "uses Event.id as the same-aggregate receiver without adding it to explicit facts" do
    runtime = boot_visibility_reaction
    door = recording_door
    event = Hecksagain::Runtime::Event.new(
      name:      "RaiseProposed",
      aggregate: "ReactionVisibility::Meter",
      id:        "meter-1",
      payload:   { reading: { value: 12 } }
    )

    Hecksagain::Runtime::PolicyInterpreter.new(runtime.registry, door: door)
                                          .react(event, "ReactionVisibility")

    expect(door.calls).to eq([
                               ["ReactionVisibility::Meter.RaiseReading", { to: "meter-1", with: { reading: { value: 12 } } }]
                             ])
  end

  it "keeps a legacy same-aggregate policy functional with Event.id only in to:" do
    runtime = boot_visibility_reaction
    door = recording_door
    event = Hecksagain::Runtime::Event.new(
      name:      "MeterObserved",
      aggregate: "ReactionVisibility::Meter",
      id:        "meter-1",
      payload:   {}
    )

    Hecksagain::Runtime::PolicyInterpreter.new(runtime.registry, door: door)
                                          .react(event, "ReactionVisibility")

    expect(door.calls).to eq([
                               ["ReactionVisibility::Meter.Touch", { to: "meter-1" }]
                             ])
  end

  it "keeps an explicitly mapped receiver authoritative over Event.id" do
    runtime = boot_visibility_reaction

    invocation = Hecksagain::Runtime::ReactionInvocation.build(
      registry:        runtime.registry,
      verb:            "ReactionVisibility::Meter.RaiseReading",
      projected:       { meter: "meter-2", reading: { value: 12 } },
      explicit:        true,
      source_receiver: { aggregate: "ReactionVisibility::Meter", identity: "meter-1" }
    )

    expect(invocation).to eq(to: "meter-2", with: { reading: { value: 12 } })
  end

  it "does not inherit Event.id from another domain's same-named aggregate" do
    runtime = boot_visibility_reaction

    invocation = Hecksagain::Runtime::ReactionInvocation.build(
      registry:        runtime.registry,
      verb:            "ReactionVisibility::Meter.Touch",
      projected:       {},
      explicit:        false,
      source_receiver: { aggregate: "OtherDomain::Meter", identity: "meter-1" }
    )

    expect(invocation).to eq({})
  end

  it "refuses a source that no reaction lexical scope declares" do
    expect do
      Hecksagain::Runtime::ReactionInvocation.resolve_mapping(
        with_spec: { reading: :parent_reading },
        scopes:    [["event payload", { reading: { value: 12 } }]],
        label:     "ApplyProposal's trigger"
      )
    end.to raise_error(
      Hecksagain::Runtime::UnknownArgument,
      /ApplyProposal's trigger's with: reads :parent_reading, which is not visible in event payload/
    )
  end

  it "preserves an explicitly empty projection instead of reverting to legacy forwarding" do
    policy, dispatch = Hecksagain::Bluebook::MetaValidator.while_shadow_parsing do
      policy_builder = Hecksagain::Bluebook::DSL::PolicyBuilder.new("EmptyProjection")
      policy_builder.trigger("Meter.RaiseReading", with: {})
      handler = Hecksagain::Bluebook::DSL::ProcessManagerBuilder::HandlerBuilder.new
      handler.dispatch("Meter.RaiseReading", with: {})
      [policy_builder.build, handler.dispatches.first]
    end

    expect(Hecksagain::Runtime::ReactionInvocation.projection_declared?(policy)).to be(true)
    expect(Hecksagain::Runtime::ReactionInvocation.projection_declared?(dispatch)).to be(true)
  end
end
