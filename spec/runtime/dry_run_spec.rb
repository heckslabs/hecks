require "spec_helper"

# Dispatcher#dry_run?'s own comment has the full reasoning — built for a
# downstream chess domain's own whole-board postcondition tests ("does
# this move leave my own king in check"), which previously had to
# dispatch a real, unrelated piece's own move purely to trigger the
# check, and that move then had to avoid interfering with the very
# position being tested. Reuses the delegates_to fixture — it already
# has a plain entity command (Piece.Move) AND a delegating aggregate
# command (Board.MovePiece) AND a policy reacting to the entity's own
# event, which is exactly the surface dry_run needs to prove itself
# against: does a dry run see through the delegation, and does it
# correctly reach NEITHER persistence NOR reactions in either shape.
RSpec.describe "Dispatcher#dry_run?" do
  DRY_RUN_FIXTURE = File.join(InMemoryDomain::ROOT, "spec/fixtures/delegates_to/delegates_to.bluebook")

  def boot
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(DRY_RUN_FIXTURE)
      Hecksagain::Runtime::Loader.bind_runtime(
        Hecksagain::Runtime::Dispatcher.new(registry)
      )
    end
  end

  def board(runtime, name)
    runtime.registry.repository("DelegatesTo", runtime.registry.bluebook("DelegatesTo").aggregate("Board")).find(name)
  end

  it "returns true for a legal entity command, and persists nothing" do
    runtime = boot
    runtime.dispatch("DelegatesTo::Board.OpenBoard", name: { value: "b1" })
    runtime.dispatch("DelegatesTo::Board.PlacePiece", name: "b1", id: { value: "p1" }, square: { file: 3, rank: 3 })

    result = runtime.dry_run?("DelegatesTo::Board.Piece.Move", name: "b1", id: { value: "p1" }, to: { file: 5, rank: 5 })

    expect(result).to be(true)
    expect(board(runtime, "b1")[:pieces].first[:square].to_h).to eq(file: 3, rank: 3)
  end

  it "raises the same refusal a real dispatch would, for the same entity command" do
    runtime = boot
    runtime.dispatch("DelegatesTo::Board.OpenBoard", name: { value: "b2" })
    runtime.dispatch("DelegatesTo::Board.PlacePiece", name: "b2", id: { value: "p1" }, square: { file: 3, rank: 3 })

    expect {
      runtime.dry_run?("DelegatesTo::Board.Piece.Move", name: "b2", id: { value: "p1" }, to: { file: 3, rank: 3 })
    }.to raise_error(Hecksagain::Runtime::GivenNotMet, /destination differs from current square/)
  end

  # THE SHAPE dry_run WAS BUILT FOR — a `delegates_to` command's own
  # in-memory mutation, reached through EntityElement.locate_chain the
  # same way a real dispatch reaches it, discarded because step_save
  # never runs. Proves dry_run? sees straight through the delegation,
  # not just a plain entity command.
  it "sees through delegates_to too — persists nothing from the delegated entity's own mutation" do
    runtime = boot
    runtime.dispatch("DelegatesTo::Board.OpenBoard", name: { value: "b3" })
    runtime.dispatch("DelegatesTo::Board.PlacePiece", name: "b3", id: { value: "p1" }, square: { file: 3, rank: 3 })

    result = runtime.dry_run?("DelegatesTo::Board.MovePiece", name: "b3", id: { value: "p1" }, to: { file: 5, rank: 5 })

    expect(result).to be(true)
    expect(board(runtime, "b3")[:pieces].first[:square].to_h).to eq(file: 3, rank: 3)
  end

  # POLICIES MUST NEVER FIRE — `move_count` (bumped by
  # OnPieceMovedBumpMoveCount, the same policy delegates_to_spec.rb's
  # own ambient-args test uses) staying at its default proves
  # Dispatcher#dry_run? never reaches `announced.each { @policies.react
  # }` at all, not merely that it reacted and rescued something.
  it "never triggers a policy reaction — nothing was announced to react to" do
    runtime = boot
    runtime.dispatch("DelegatesTo::Board.OpenBoard", name: { value: "b4" })
    runtime.dispatch("DelegatesTo::Board.PlacePiece", name: "b4", id: { value: "p1" }, square: { file: 3, rank: 3 })

    runtime.dry_run?("DelegatesTo::Board.MovePiece", name: "b4", id: { value: "p1" }, to: { file: 5, rank: 5 })

    expect(board(runtime, "b4")[:move_count].to_h).to eq(value: 0)
  end

  it "leaves a real dispatch working normally afterward — no residue from the dry run" do
    runtime = boot
    runtime.dispatch("DelegatesTo::Board.OpenBoard", name: { value: "b5" })
    runtime.dispatch("DelegatesTo::Board.PlacePiece", name: "b5", id: { value: "p1" }, square: { file: 3, rank: 3 })

    runtime.dry_run?("DelegatesTo::Board.MovePiece", name: "b5", id: { value: "p1" }, to: { file: 5, rank: 5 })
    runtime.dispatch("DelegatesTo::Board.MovePiece", to: "b5", with: { id: { value: "p1" }, to: { file: 6, rank: 6 } })

    expect(board(runtime, "b5")[:pieces].first[:square].to_h).to eq(file: 6, rank: 6)
    expect(board(runtime, "b5")[:move_count].to_h).to eq(value: 1)
  end

  # No port-bearing fixture was worth building fresh for this alone —
  # the guard itself is a plain, direct `if aggregate.port(head) then
  # raise else entity dispatch` two-liner in Dispatcher#dry_run?, read
  # and confirmed correct rather than exercised through a dedicated
  # fixture. Named here so the gap is visible, not silently assumed
  # covered.
end
