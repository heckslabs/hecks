require "spec_helper"

# A POLICY'S `with:` MAY READ THE EMITTING RECORD'S OWN IDENTITY.
#
# Routing separated from payload (`to:`/`with:`) stopped carrying the
# emitting aggregate's identity in an event's payload — right for the
# event, but it left a CROSS-aggregate reaction with no way to say which
# record to address. The real case: chess's Graveyard is one per game,
# fed by policy from every piece's own Captured event; an entity
# command's event never declares its aggregate's identity (it arrives
# through `reference_to`), so `with: { label: :label }` was refused at
# build time and a wholesale forward fell through to the captured
# piece's `id` as the graveyard's identity — every burial refused.
#
# `PolicyInterpreter#emitter_identity` offers `Event#id` under the
# emitter's own identity heads, to an explicit projection only;
# `BluebookBuilder.check_with_spec!` admits the same names.
RSpec.describe "a policy projecting its emitter's identity" do
  def boot_board(with_spec)
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)

      Hecks.bluebook "Boards" do
        aggregate "Board" do
          attribute :label,  Label
          attribute :pieces, list_of(Piece)
          identified_by :label

          value_object("Label")   { attribute :value, String }
          value_object("PieceId") { attribute :value, String }

          entity "Piece" do
            attribute :id, PieceId
            identified_by :id

            lifecycle :status, default: "on_board" do
              transition "Capture" => "captured", from: "on_board"
            end

            command "Capture", from: "on_board" do
              emits "PieceCaptured"
            end
          end

          command "Create" do
            attribute :label, Label
            sets :label
            emits "BoardCreated"
          end

          command "Place" do
            reference_to Board
            attribute :id, PieceId
            sets :pieces, append: { id: :id }
            emits "PiecePlaced"
          end

          command "CapturePiece" do
            reference_to Board
            attribute :id, PieceId
            delegates_to "Piece.Capture", with: { id: :id }
          end
        end

        aggregate "Graveyard" do
          attribute :label,  Label
          attribute :fallen, list_of(Fallen)
          identified_by :label

          value_object("Label")   { attribute :value, String }
          value_object("PieceId") { attribute :value, String }

          entity "Fallen" do
            attribute :id, PieceId
            identified_by :id
          end

          command "Open" do
            attribute :label, Label
            sets :label
            emits "GraveyardOpened"
          end

          command "Bury" do
            reference_to Graveyard
            attribute :id, PieceId
            sets :fallen, append: { id: :id }
            emits "PieceBuried"
          end
        end

        policy "OpenWithBoard" do
          on      "BoardCreated"
          trigger Graveyard::Open
        end

        # THE POINT: `PieceCaptured` declares nothing — the board's own
        # `label` only ever reaches this projection as the emitter's identity.
        policy "BuryOnCapture" do
          on      "PieceCaptured"
          trigger Graveyard::Bury, with: with_spec
        end
      end

      Hecks.hecksagon("Boards") do
        ::Boards::Board.persisted_by("Memory")
        ::Boards::Graveyard.persisted_by("Memory")
      end
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  it "addresses another aggregate by the identity of the record that emitted the event" do
    runtime = boot_board({ label: :label, id: :id })
    runtime.dispatch("Boards::Board.Create", label: { value: "g" })
    runtime.dispatch("Boards::Board.Place", to: "g", with: { id: "p1" })
    runtime.dispatch("Boards::Board.CapturePiece", to: "g", with: { id: "p1" })

    burial = runtime.reactions.find { |row| row[:policy] == "BuryOnCapture" }
    expect(burial).to include(delivered: true)
    expect(runtime.registry.event_log.map(&:name).last(2)).to eq(%w[PieceCaptured PieceBuried])
    fallen = Boards::Graveyard.find("g").fallen.map { |f| Hecks::Runtime::Value.materialize(f) }
    expect(fallen).to eq([{ id: { value: "p1" } }])
  end

  it "never lets the identity shadow a field the payload itself carries" do
    runtime = boot_board({ label: :label, id: :id })
    runtime.dispatch("Boards::Board.Create", label: { value: "g" })
    runtime.dispatch("Boards::Board.Place", to: "g", with: { id: "p1" })
    runtime.dispatch("Boards::Board.CapturePiece", to: "g", with: { id: "p1" })

    bound = runtime.registry.policy_dispatch_log.find { |row| row[:policy] == "BuryOnCapture" }
    expect(bound[:payload]).to include(label: "g", id: Hecks::Runtime::Value)
    # The fuzzer's independent re-derivation of the binding reads the
    # same merged source, so the two never disagree.
    require "hecks/fuzzing/properties"
    expect(Hecks::Fuzzing::Properties.dispatch_binding_fidelity(
             policy_dispatches: runtime.registry.policy_dispatch_log
           )).to be(true)
  end

  it "still refuses a source the event neither declares nor identifies" do
    expect { boot_board({ label: :board_name, id: :id }) }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /reads :board_name off "PieceCaptured", which does not declare it/)
  end
end
