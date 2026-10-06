require "spec_helper"

RSpec.describe "policy and process lexical visibility" do
  REACTION_VISIBILITY_DOMAIN = proc do
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

  REACTION_RAISE_READING_CALL = [
    "ReactionVisibility::Meter.RaiseReading", { to: "meter-1", with: { reading: { value: 12 } } }
  ].freeze

  def boot_visibility_reaction
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Hecks.bluebook("ReactionVisibility", &REACTION_VISIBILITY_DOMAIN)
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
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

  # An installed meter whose reentered reactions are recorded, still running the real dispatch.
  def spied_meter_runtime
    runtime = boot_visibility_reaction
    runtime.dispatch("ReactionVisibility::Meter.Install", with: { code: { value: "meter-1" }, reading: { value: 10 } })
    calls = []
    real_reenter = runtime.method(:reenter)
    runtime.define_singleton_method(:reenter) do |verb, **arguments|
      calls << [verb, arguments]
      real_reenter.call(verb, **arguments)
    end
    [runtime, calls]
  end

  def report_proposal(runtime)
    runtime.dispatch(
      "ReactionVisibility::Proposal.Report",
      with: {
        reference:              { value: "proposal-1" },
        meter:                  "meter-1",
        reading:                { value: 12 },
        claimed_parent_reading: { value: 999 }
      }
    )
  end

  # The calls the policies answering `name` make through a recording door.
  def calls_reacting_to(name, payload)
    door = recording_door
    event = Hecks::Runtime::Event.new(name: name, aggregate: "ReactionVisibility::Meter", id: "meter-1", payload: payload)
    Hecks::Runtime::PolicyInterpreter.new(boot_visibility_reaction.registry, door: door)
                                     .react(event, "ReactionVisibility")
    door.calls
  end

  def built_invocation(verb, projected, explicit, source_receiver)
    Hecks::Runtime::ReactionInvocation.build(
      registry: boot_visibility_reaction.registry, verb: verb, projected: projected, explicit: explicit,
      source_receiver: source_receiver
    )
  end

  def resolved_mapping
    Hecks::Runtime::ReactionInvocation.resolve_mapping(
      with_spec: { current: :amount, remembered: :destination, correlation: :reference },
      scopes:    [
        ["current event payload", { amount: { cents: 20 } }],
        ["opening event memory", { amount: { cents: 10 }, destination: "account-2" }]
      ],
      bindings:  { reference: "transfer-1" },
      label:     "Settlement's dispatch"
    )
  end

  def resolve_invisible_source
    Hecks::Runtime::ReactionInvocation.resolve_mapping(
      with_spec: { reading: :parent_reading },
      scopes:    [["event payload", { reading: { value: 12 } }]],
      label:     "ApplyProposal's trigger"
    )
  end

  def empty_projection_pair
    Hecks::Bluebook::MetaValidator.while_shadow_parsing do
      policy_builder = Hecks::Bluebook::DSL::PolicyBuilder.new("EmptyProjection")
      policy_builder.trigger("Meter.RaiseReading", with: {})
      handler = Hecks::Bluebook::DSL::ProcessManagerBuilder::HandlerBuilder.new
      handler.dispatch("Meter.RaiseReading", with: {})
      [policy_builder.build, handler.dispatches.first]
    end
  end

  it "routes identity, maps event facts, and leaves target parent state lexical", :aggregate_failures do
    runtime, calls = spied_meter_runtime

    report_proposal(runtime)

    expect(calls).to include(REACTION_RAISE_READING_CALL)
    expect(ReactionVisibility::Meter.find("meter-1").reading.to_h).to eq(value: 12)
  end

  it "resolves process mappings through current event, opening memory, then explicit correlation" do
    expect(resolved_mapping).to eq(current: { cents: 20 }, remembered: "account-2", correlation: "transfer-1")
  end

  it "uses Event.id as the same-aggregate receiver without adding it to explicit facts" do
    expect(calls_reacting_to("RaiseProposed", { reading: { value: 12 } })).to eq([REACTION_RAISE_READING_CALL])
  end

  it "keeps a legacy same-aggregate policy functional with Event.id only in to:" do
    expect(calls_reacting_to("MeterObserved", {})).to eq([["ReactionVisibility::Meter.Touch", { to: "meter-1" }]])
  end

  it "keeps an explicitly mapped receiver authoritative over Event.id" do
    invocation = built_invocation("ReactionVisibility::Meter.RaiseReading", { meter: "meter-2", reading: { value: 12 } },
                                  true, { aggregate: "ReactionVisibility::Meter", identity: "meter-1" })

    expect(invocation).to eq(to: "meter-2", with: { reading: { value: 12 } })
  end

  it "does not inherit Event.id from another domain's same-named aggregate" do
    invocation = built_invocation("ReactionVisibility::Meter.Touch", {}, false,
                                  { aggregate: "OtherDomain::Meter", identity: "meter-1" })

    expect(invocation).to eq({})
  end

  it "refuses a source that no reaction lexical scope declares" do
    expect { resolve_invisible_source }.to raise_error(
      Hecks::Runtime::UnknownArgument,
      /ApplyProposal's trigger's with: reads :parent_reading, which is not visible in event payload.*\(visible — /
    )
  end

  it "preserves an explicitly empty projection instead of reverting to legacy forwarding", :aggregate_failures do
    policy, dispatch = empty_projection_pair

    expect(Hecks::Runtime::ReactionInvocation.projection_declared?(policy)).to be(true)
    expect(Hecks::Runtime::ReactionInvocation.projection_declared?(dispatch)).to be(true)
  end
end
