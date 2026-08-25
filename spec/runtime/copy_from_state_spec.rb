require "spec_helper"

# `state(:field)` AS A MUTATION SOURCE — the record's own value copied
# into an appended element or onto another field. A bare Symbol always
# names a command argument, so before this a command could not snapshot
# its own record at all: chess's threefold repetition needs the board's
# piece lists copied off the record every ply, and nothing a caller
# hands in can be trusted to be that.
RSpec.describe "a mutation sourced from the record's own state" do
  def boot_board
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)

      Hecks.bluebook "Snapshots" do
        aggregate "Board" do
          attribute :label,     Label
          attribute :ply,       Ply
          attribute :last_ply,  Ply, optional: true
          attribute :pieces,    list_of(Piece)
          attribute :positions, list_of(Position)
          identified_by :label

          value_object("Label")   { attribute :value, String }
          value_object("PieceId") { attribute :value, String }
          value_object("Ply")     { attribute :value, Integer }
          value_object("Square")  { attribute :file, Integer }

          # ONE SNAPSHOT: the ply it was taken at and the pieces as they
          # stood — a list of the aggregate's own entity records, held
          # by a value object.
          value_object "Position" do
            attribute :ply,    Ply
            attribute :pieces, list_of(Piece)
          end

          entity "Piece" do
            attribute :id,     PieceId
            attribute :square, Square
            identified_by :id

            command "Move" do
              attribute :to, Square
              sets :square, to: :to
              emits "PieceMoved"
            end
          end

          command "Create" do
            attribute :label, Label
            sets :label
            sets :ply, to: { value: 0 }
            emits "BoardCreated"
          end

          command "Place" do
            reference_to Board
            attribute :id,     PieceId
            attribute :square, Square
            sets :pieces, append: { id: :id, square: :square }
            emits "PiecePlaced"
          end

          command "MovePiece" do
            reference_to Board
            attribute :id, PieceId
            attribute :to, Square
            delegates_to "Piece.Move", with: { id: :id, to: :to }
          end

          # THE POINT: declares no argument, reads two fields off the record.
          command "Record" do
            reference_to Board
            sets :positions, append: { ply: state(:ply), pieces: state(:pieces) }
            sets :last_ply, to: state(:ply)
            sets :ply, increment: { value: 1 }
            emits "PositionRecorded"
          end

          command "ClaimRepeat" do
            goal "The current pieces stood exactly so at an earlier recorded ply"
            reference_to Board
            given("some earlier position has every piece where it stands now") do
              positions.any? { |p| pieces.all? { |k| p.pieces.any? { |s| s.id == k.id && s.square.file == k.square.file } } }
            end
            emits "RepeatClaimed"
          end
        end
      end

      Hecks.hecksagon("Snapshots") { ::Snapshots::Board.persisted_by("Memory") }
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let(:runtime) do
    boot_board.tap do |bound|
      bound.dispatch("Snapshots::Board.Create", label: { value: "b" })
      bound.dispatch("Snapshots::Board.Place", to: "b", with: { id: "p1", square: { file: 1 } })
    end
  end

  def board = Hecks::Runtime::Value.materialize(Snapshots::Board.find("b").to_h)

  it "copies the record's own fields into the appended element, and asks the caller for nothing" do
    runtime.dispatch("Snapshots::Board.Record", to: "b", with: {})

    expect(board[:positions]).to eq([{ ply: { value: 0 }, pieces: [{ id: { value: "p1" }, square: { file: 1 } }] }])
    expect(board[:last_ply]).to eq(value: 0)
    expect(board[:ply]).to eq(value: 1)
  end

  it "snapshots by value — a later move does not rewrite an earlier position" do
    runtime.dispatch("Snapshots::Board.Record", to: "b", with: {})
    runtime.dispatch("Snapshots::Board.MovePiece", to: "b", with: { id: "p1", to: { file: 2 } })

    expect(board[:positions].first[:pieces]).to eq([{ id: { value: "p1" }, square: { file: 1 } }])
    expect(board[:pieces]).to eq([{ id: { value: "p1" }, square: { file: 2 } }])
  end

  it "lets a given quantify over the snapshot's own list" do
    runtime.dispatch("Snapshots::Board.Record", to: "b", with: {})
    runtime.dispatch("Snapshots::Board.MovePiece", to: "b", with: { id: "p1", to: { file: 2 } })
    expect { runtime.dispatch("Snapshots::Board.ClaimRepeat", to: "b", with: {}) }
      .to raise_error(Hecks::Runtime::GivenNotMet)

    runtime.dispatch("Snapshots::Board.MovePiece", to: "b", with: { id: "p1", to: { file: 1 } })
    expect(runtime.dispatch("Snapshots::Board.ClaimRepeat", to: "b", with: {}).events.map(&:name)).to eq(["RepeatClaimed"])
  end

  it "carries the source through the IR as its own kind" do
    command = runtime.registry.bluebook("Snapshots").aggregate("Board").command("Record")
    mutations = command.mutations.map(&:to_h)
    expect(mutations[0][:fields]).to eq(ply: "state(:ply)", pieces: "state(:pieces)")
    expect(mutations[1][:source]).to eq(kind: "state", name: "ply")
  end
end
