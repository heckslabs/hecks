require "spec_helper"
require "hecks/fuzzing/properties"

# A policy's `with:` may read the emitting record's own identity, offered by
# `PolicyInterpreter#emitter_identity` as `Event#id` under the emitter's identity heads.
RSpec.describe "a policy projecting its emitter's identity" do
  # One inline bluebook, declared whole — a domain-definition DSL block
  # read top to bottom as the fixture, not a sequence of independent
  # steps; splitting it would scatter one readable declaration across
  # several methods that only make sense read back-to-back.
  # rubocop:disable-next Metrics/AbcSize
  # rubocop:disable-next Metrics/MethodLength
  def boot_board(with_spec)
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      MemoryPorts.load!

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

        # `PieceCaptured` declares nothing: `label` reaches this projection
        # only as the emitter's identity.
        policy "BuryOnCapture" do
          on      "PieceCaptured"
          trigger Graveyard::Bury, with: with_spec
        end
      end

      Hecks.hecksagon("Boards") do
        Boards::Board.persisted_by("Memory")
        Boards::Graveyard.persisted_by("Memory")
      end
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  # A board "g" whose piece "p1" was placed and then captured, under the given trigger projection.
  def captured_board(with_spec)
    runtime = boot_board(with_spec)
    runtime.dispatch_flat("Boards::Board.Create", label: { value: "g" })
    runtime.dispatch("Boards::Board.Place", to: "g", with: { id: "p1" })
    runtime.dispatch("Boards::Board.CapturePiece", to: "g", with: { id: "p1" })
    runtime
  end

  def buried_pieces
    Boards::Graveyard.find("g").fallen.map { |f| Hecks::Runtime::Value.materialize(f) }
  end

  it "addresses another aggregate by the identity of the record that emitted the event", :aggregate_failures do
    runtime = captured_board({ label: :label, id: :id })

    expect(runtime.reactions.find { |row| row[:policy] == "BuryOnCapture" }).to include(delivered: true)
    expect(runtime.registry.event_log.map(&:name).last(2)).to eq(%w[PieceCaptured PieceBuried])
    expect(buried_pieces).to eq([{ id: { value: "p1" } }])
  end

  it "never lets the identity shadow a field the payload itself carries", :aggregate_failures do
    runtime = captured_board({ label: :label, id: :id })

    bound = runtime.registry.policy_dispatch_log.find { |row| row[:policy] == "BuryOnCapture" }
    expect(bound[:payload]).to include(label: "g", id: Hecks::Runtime::Value)
    # The fuzzer's independent re-derivation of the binding reads the
    # same merged source, so the two never disagree.
    expect(Hecks::Fuzzing::Properties.dispatch_binding_fidelity(policy_dispatches: runtime.registry.policy_dispatch_log))
      .to be(true)
  end

  it "still refuses a source the event neither declares nor identifies" do
    expect { boot_board({ label: :board_name, id: :id }) }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /reads :board_name off "PieceCaptured", which does not declare it/)
  end

  # A two-field identity whose event carries neither field by the name `id`: the policy can
  # hand the whole of it to another aggregate only by reading `:id` (ADR 0144).
  # rubocop:disable-next Metrics/AbcSize
  # rubocop:disable-next Metrics/MethodLength
  def boot_id_reader
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      MemoryPorts.load!

      Hecks.bluebook "Ids" do
        aggregate "Slot" do
          attribute :row,  Row
          attribute :seat, Seat
          identified_by :row, :seat
          value_object("Row")  { attribute :value, String }
          value_object("Seat") { attribute :value, String }

          command "Take" do
            attribute :row, Row
            attribute :seat, Seat
            sets :row
            sets :seat
            emits "SlotTaken"
          end
        end

        aggregate "Note" do
          attribute :key, Key
          identified_by :key
          value_object("Key") { attribute :value, String }

          command "Write" do
            attribute :key, Key
            sets :key
            emits "NoteWritten"
          end
        end

        policy "NoteTheSlot" do
          on      "SlotTaken"
          trigger Note::Write, with: { key: :id }
        end
      end

      Hecks.hecksagon("Ids") do
        Ids::Slot.persisted_by("Memory")
        Ids::Note.persisted_by("Memory")
      end
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  it "reads a composite identity whole as :id, joined by a colon", :aggregate_failures do
    runtime = boot_id_reader
    runtime.dispatch_flat("Ids::Slot.Take", row: { value: "A" }, seat: { value: "7" })

    expect(runtime.reactions.find { |row| row[:policy] == "NoteTheSlot" }).to include(delivered: true)
    expect(Ids::Note.find("A:7")).not_to be_nil
  end
end
