require "spec_helper"

# Dispatch-level coverage of `delegates_to`: synchronous refusal propagation and atomic
# persistence, which `trigger` and a saga's `dispatches` cannot give.
RSpec.describe "an aggregate command that delegates_to one nested entity command" do
  DELEGATES_TO_FIXTURE = File.join(InMemoryDomain::ROOT, "spec/fixtures/delegates_to/delegates_to.bluebook")

  def boot
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(DELEGATES_TO_FIXTURE)
      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    end
  end

  def board_record(runtime, name)
    board = runtime.registry.bluebook("DelegatesTo").aggregate("Board")
    runtime.registry.repository("DelegatesTo", board).find(name)
  end

  # `.first`, not a `find` on id: a stored id may round-trip as a String or a wrapped Value.
  def square(runtime, name:) = board_record(runtime, name)[:pieces].first[:square]

  def board_with_piece(name)
    runtime = boot
    runtime.dispatch_flat("DelegatesTo::Board.OpenBoard", name: { value: name })
    runtime.dispatch_flat("DelegatesTo::Board.PlacePiece", name: name, id: { value: "p1" }, square: { file: 3, rank: 3 })
    runtime
  end

  def move_piece(runtime, name, file, rank)
    runtime.dispatch("DelegatesTo::Board.MovePiece", to: name, with: { id: { value: "p1" }, to: { file: file, rank: rank } })
  end

  def relabel_directly(runtime, name)
    runtime.dispatch("DelegatesTo::Board.Piece.Relabel",
                     to:   { aggregate: name, entity: "p1" },
                     with: { destination: { file: 5, rank: 5 } })
  end

  def relabel_through_board(runtime, name)
    runtime.dispatch("DelegatesTo::Board.RelabelPiece",
                     to:   name,
                     with: { id: { value: "p1" }, destination: { file: 5, rank: 5 } })
  end

  it "mutates the target entity and emits its own event, in ONE dispatch that never names the entity", :aggregate_failures do
    runtime = board_with_piece("b1")

    result = move_piece(runtime, "b1", 5, 5)

    expect(result.events.map(&:name)).to eq(["PieceMoved"])
    expect(square(runtime, name: "b1").to_h).to eq(file: 5, rank: 5)
  end

  # `with:` only remaps what it names, so `target_args` must start from the delegating
  # command's resolved args; otherwise a policy re-locating Board by `name` finds nothing.
  it "carries the delegating command's own ambient args through to the target's own emitted event" do
    runtime = board_with_piece("b4")

    move_piece(runtime, "b4", 5, 5)

    expect(board_record(runtime, "b4")[:move_count].to_h).to eq(value: 1)
  end

  it "raises the target's own refusal AS the delegating command's own refusal — synchronously, not recorded and swallowed" do
    runtime = board_with_piece("b2")

    expect { move_piece(runtime, "b2", 3, 3) }
      .to raise_error(Hecks::Runtime::GivenNotMet, /destination differs from current square/)
  end

  it "persists nothing from a refused delegation — the failed attempt leaves the piece exactly where it was",
     :aggregate_failures do
    runtime = board_with_piece("b3")

    expect { move_piece(runtime, "b3", 3, 3) }.to raise_error(Hecks::Runtime::GivenNotMet)

    expect(square(runtime, name: "b3").to_h).to eq(file: 3, rank: 3)
  end

  # BUG#148 — `step_delegate_to_entity` never runs `refuse_unknown_arguments`,
  # `refuse_absent_arguments`, or `normalize_args` on the target command's own
  # already-mapped args before dispatching it inline, unlike `EntityInterpreter`'s
  # direct-dispatch path. `Piece.Relabel` declares `reason` as required; dispatching it
  # directly without one correctly refuses, but `RelabelPiece`'s `with:` never names
  # `reason` (and never declares it itself), so the exact same omission must refuse the
  # same way when reached through the delegating aggregate command.
  it "refuses the same absent required argument whether the entity command is dispatched directly " \
     "or through delegates_to", :aggregate_failures do
    runtime = board_with_piece("b5")

    expect { relabel_directly(runtime, "b5") }.to raise_error(Hecks::Runtime::AbsentArgument, /reason/)
    expect { relabel_through_board(runtime, "b5") }.to raise_error(Hecks::Runtime::AbsentArgument, /reason/)
    expect(square(runtime, name: "b5").to_h).to eq(file: 3, rank: 3)
  end
end
