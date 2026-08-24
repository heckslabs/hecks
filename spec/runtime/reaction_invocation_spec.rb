require "spec_helper"

RSpec.describe "reaction invocation routing" do
  class RecordingReactionDoor
    attr_reader :calls

    def initialize
      @calls = []
    end

    def reenter(verb, **arguments)
      @calls << [verb, arguments]
    end

    def reaction_depth_reached? = false
    def max_reaction_depth = 16
  end

  def reaction_registry
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Hecks.bluebook "ReactionRouting" do
        aggregate "Permit" do
          attribute :code, Code
          identified_by :code

          value_object("Code") { attribute :value, String }
          value_object("Day")  { attribute :value, String }
          value_object("Note") { attribute :text, String }

          command "Grant" do
            attribute :code, Code
            sets :code
            emits "PermitGranted"
          end

          command "Revoke" do
            reference_to Permit
            emits "PermitRevoked"
          end

          entity "Review" do
            attribute :reviewed_on, Day
            identified_by :reviewed_on

            command "Annotate" do
              attribute :note, Note
              sets :note
              emits "ReviewAnnotated"
            end
          end
        end

        policy "RevokeFlaggedPermit" do
          on "PermitFlagged"
          trigger Permit::Revoke, with: { permit: :permit }
        end
      end
    end

    registry
  end

  it "keeps an explicitly projected aggregate receiver out of command facts" do
    registry = reaction_registry
    door = RecordingReactionDoor.new
    event = Hecks::Runtime::Event.new(
      name: "PermitFlagged", aggregate: "Signal", id: "signal-1", payload: { permit: "permit-1" }
    )

    Hecks::Runtime::PolicyInterpreter.new(registry, door: door).react(event, "ReactionRouting")

    expect(door.calls).to eq([
                               ["ReactionRouting::Permit.Revoke", { to: "permit-1", with: {} }]
                             ])
  end

  it "orders aggregate and entity identities outside an entity command's facts" do
    invocation = Hecks::Runtime::ReactionInvocation.build(
      registry:  reaction_registry,
      verb:      "ReactionRouting::Permit.Review.Annotate",
      projected: {
        code:        { value: "permit-1" },
        reviewed_on: { value: "2026-08-18" },
        note:        { text: "manual review" }
      },
      explicit:  true
    )

    expect(invocation).to eq(
      to:   { aggregate: "permit-1", entities: ["2026-08-18"] },
      with: { note: { text: "manual review" } }
    )
  end

  it "separates a process manager's receiver and correlation passthrough from its declared facts" do
    registry = Hecks::Runtime::Registry.new
    fixture = File.join(InMemoryDomain::ROOT, "spec/fixtures/settlement.bluebook")
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(fixture)
    end
    process_manager = registry.bluebook("Wire").process_managers.find { |candidate| candidate.name == "Carry" }
    handler = process_manager.handler_for("WireAsked")
    dispatch = handler.dispatches.first
    door = RecordingReactionDoor.new
    event = Hecks::Runtime::Event.new(
      name:      "WireAsked",
      aggregate: "Wire",
      id:        "wire-1",
      payload:   {
        reference:   { value: "wire-1" },
        source:      "left",
        destination: "right",
        amount:      { cents: 250 }
      }
    )
    instance = { state: "asked", memory: event.payload }

    Hecks::Runtime::SagaInterpreter.new(registry, door: door).send(
      :deliver_saga_dispatch,
      process_manager, dispatch, event, instance, "wire-1", "Wire"
    )

    expect(door.calls).to eq([
                               [
                                 "Wire::Drawer.Take",
                                 {
                                   saga_correlation: { "reference" => "wire-1" },
                                   to:               "left",
                                   with:             { amount: { cents: 250 } }
                                 }
                               ]
                             ])
  end
end
