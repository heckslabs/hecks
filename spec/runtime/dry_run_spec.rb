require "spec_helper"

# Reuses the delegates_to fixture: a plain entity command, a delegating aggregate command and a
# policy reacting to the entity's event.
RSpec.describe "Dispatcher#dry_run?" do
  DRY_RUN_FIXTURE = File.join(InMemoryDomain::ROOT, "spec/fixtures/delegates_to/delegates_to.bluebook")

  def boot
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(DRY_RUN_FIXTURE)
      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    end
  end

  def board(runtime, name)
    runtime.registry.repository("DelegatesTo", runtime.registry.bluebook("DelegatesTo").aggregate("Board")).find(name)
  end

  def square_of(runtime, name) = board(runtime, name)[:pieces].first[:square].to_h

  def board_with_piece(name)
    runtime = boot
    runtime.dispatch_flat("DelegatesTo::Board.OpenBoard", name: { value: name })
    runtime.dispatch_flat("DelegatesTo::Board.PlacePiece", name: name, id: { value: "p1" }, square: { file: 3, rank: 3 })
    runtime
  end

  def dry_run_move?(runtime, verb, name, file, rank)
    runtime.dry_run?("DelegatesTo::Board.#{verb}", name: name, id: { value: "p1" }, to: { file: file, rank: rank })
  end

  it "returns true for a legal entity command, and persists nothing", :aggregate_failures do
    runtime = board_with_piece("b1")

    expect(dry_run_move?(runtime, "Piece.Move", "b1", 5, 5)).to be(true)
    expect(square_of(runtime, "b1")).to eq(file: 3, rank: 3)
  end

  it "raises the same refusal a real dispatch would, for the same entity command" do
    runtime = board_with_piece("b2")

    expect { dry_run_move?(runtime, "Piece.Move", "b2", 3, 3) }
      .to raise_error(Hecks::Runtime::GivenNotMet, /destination differs from current square/)
  end

  # A delegated entity mutation is discarded too, not only a plain entity command's.
  it "sees through delegates_to too — persists nothing from the delegated entity's own mutation", :aggregate_failures do
    runtime = board_with_piece("b3")

    expect(dry_run_move?(runtime, "MovePiece", "b3", 5, 5)).to be(true)
    expect(square_of(runtime, "b3")).to eq(file: 3, rank: 3)
  end

  # `move_count` (bumped by OnPieceMovedBumpMoveCount) staying at its default proves no policy ran.
  it "never triggers a policy reaction — nothing was announced to react to" do
    runtime = board_with_piece("b4")

    dry_run_move?(runtime, "MovePiece", "b4", 5, 5)

    expect(board(runtime, "b4")[:move_count].to_h).to eq(value: 0)
  end

  it "leaves a real dispatch working normally afterward — no residue from the dry run", :aggregate_failures do
    runtime = board_with_piece("b5")

    dry_run_move?(runtime, "MovePiece", "b5", 5, 5)
    runtime.dispatch("DelegatesTo::Board.MovePiece", to: "b5", with: { id: { value: "p1" }, to: { file: 6, rank: 6 } })

    expect(square_of(runtime, "b5")).to eq(file: 6, rank: 6)
    expect(board(runtime, "b5")[:move_count].to_h).to eq(value: 1)
  end

  # No port-bearing fixture exists, so the port guard in Dispatcher#dry_run? is not exercised here.
end
