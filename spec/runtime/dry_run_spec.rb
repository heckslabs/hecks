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
      Hecks::Runtime::Loader.bind_runtime(
        Hecks::Runtime::Dispatcher.new(registry)
      )
    end
  end

  def board(runtime, name)
    runtime.registry.repository("DelegatesTo", runtime.registry.bluebook("DelegatesTo").aggregate("Board")).find(name)
  end

  it "returns true for a legal entity command, and persists nothing" do
    runtime = boot
    runtime.dispatch_flat("DelegatesTo::Board.OpenBoard", name: { value: "b1" })
    runtime.dispatch_flat("DelegatesTo::Board.PlacePiece", name: "b1", id: { value: "p1" }, square: { file: 3, rank: 3 })

    result = runtime.dry_run?("DelegatesTo::Board.Piece.Move", name: "b1", id: { value: "p1" }, to: { file: 5, rank: 5 })

    expect(result).to be(true)
    expect(board(runtime, "b1")[:pieces].first[:square].to_h).to eq(file: 3, rank: 3)
  end

  it "raises the same refusal a real dispatch would, for the same entity command" do
    runtime = boot
    runtime.dispatch_flat("DelegatesTo::Board.OpenBoard", name: { value: "b2" })
    runtime.dispatch_flat("DelegatesTo::Board.PlacePiece", name: "b2", id: { value: "p1" }, square: { file: 3, rank: 3 })

    expect do
      runtime.dry_run?("DelegatesTo::Board.Piece.Move", name: "b2", id: { value: "p1" }, to: { file: 3, rank: 3 })
    end.to raise_error(Hecks::Runtime::GivenNotMet, /destination differs from current square/)
  end

  # A delegated entity mutation is discarded too, not only a plain entity command's.
  it "sees through delegates_to too — persists nothing from the delegated entity's own mutation" do
    runtime = boot
    runtime.dispatch_flat("DelegatesTo::Board.OpenBoard", name: { value: "b3" })
    runtime.dispatch_flat("DelegatesTo::Board.PlacePiece", name: "b3", id: { value: "p1" }, square: { file: 3, rank: 3 })

    result = runtime.dry_run?("DelegatesTo::Board.MovePiece", name: "b3", id: { value: "p1" }, to: { file: 5, rank: 5 })

    expect(result).to be(true)
    expect(board(runtime, "b3")[:pieces].first[:square].to_h).to eq(file: 3, rank: 3)
  end

  # `move_count` (bumped by OnPieceMovedBumpMoveCount) staying at its default proves no policy ran.
  it "never triggers a policy reaction — nothing was announced to react to" do
    runtime = boot
    runtime.dispatch_flat("DelegatesTo::Board.OpenBoard", name: { value: "b4" })
    runtime.dispatch_flat("DelegatesTo::Board.PlacePiece", name: "b4", id: { value: "p1" }, square: { file: 3, rank: 3 })

    runtime.dry_run?("DelegatesTo::Board.MovePiece", name: "b4", id: { value: "p1" }, to: { file: 5, rank: 5 })

    expect(board(runtime, "b4")[:move_count].to_h).to eq(value: 0)
  end

  it "leaves a real dispatch working normally afterward — no residue from the dry run" do
    runtime = boot
    runtime.dispatch_flat("DelegatesTo::Board.OpenBoard", name: { value: "b5" })
    runtime.dispatch_flat("DelegatesTo::Board.PlacePiece", name: "b5", id: { value: "p1" }, square: { file: 3, rank: 3 })

    runtime.dry_run?("DelegatesTo::Board.MovePiece", name: "b5", id: { value: "p1" }, to: { file: 5, rank: 5 })
    runtime.dispatch("DelegatesTo::Board.MovePiece", to: "b5", with: { id: { value: "p1" }, to: { file: 6, rank: 6 } })

    expect(board(runtime, "b5")[:pieces].first[:square].to_h).to eq(file: 6, rank: 6)
    expect(board(runtime, "b5")[:move_count].to_h).to eq(value: 1)
  end

  # No port-bearing fixture exists, so the port guard in Dispatcher#dry_run? is not exercised here.
end
