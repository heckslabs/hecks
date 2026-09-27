require "spec_helper"

# Two-level nested pieces (Board, Card) from qa/stress_domains/nested_pieces.
# Pins NotFound, not InvariantViolation, for an address failing its own invariant at both hops.
RSpec.describe "NestedPieces" do
  NESTED_PIECES_ROOT = File.join(InMemoryDomain::ROOT, "qa/stress_domains/nested_pieces/bluebook").freeze

  def boot_nested_pieces
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.join(NESTED_PIECES_ROOT, "nested_pieces.bluebook"))

      Hecks.hecksagon "NestedPieces" do
        uses_framework "Governance"

        NestedPieces::Workspace.persisted_by("Memory")
      end
      sibling_governance!
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let(:runtime) { boot_nested_pieces }

  # An appended entity must store a key for every declared attribute, unset ones as nil,
  # matching Rust's `to_json`, which always emits every declared field.
  it "gives a freshly appended Board and Card a key for every declared attribute, unset ones included" do
    runtime
    NestedPieces::Workspace.open!(reference: { value: "W1" })
    NestedPieces::Workspace.find("W1").add_board!(number: { value: 1 })
    runtime.dispatch_flat("NestedPieces::Workspace.Board.AddCard",
                          to: { aggregate: "W1", entity: "1" }, sequence: { value: 1 })

    workspace = NestedPieces::Workspace.find("W1")
    board = workspace[:boards].find { |b| b[:number][:value] == 1 }
    card  = board[:cards].first

    expect(board.key?(:label)).to be(true)
    expect(board[:label]).to be_nil
    expect(card.key?(:note)).to be(true)
    expect(card[:note]).to be_nil
  end

  it "opens a workspace, adds a board, and adds a card two levels deep" do
    runtime
    NestedPieces::Workspace.open!(reference: { value: "W1" })
    NestedPieces::Workspace.find("W1").add_board!(number: { value: 1 })

    runtime.dispatch_flat("NestedPieces::Workspace.Board.AddCard",
                          to: { aggregate: "W1", entity: "1" }, sequence: { value: 1 })

    workspace = NestedPieces::Workspace.find("W1")
    board = workspace[:boards].find { |b| b[:number][:value] == 1 }
    expect(board[:cards].map { |card| card[:sequence][:value] }).to eq([1])
  end

  it "labels a board and annotates a card two levels deep, ordinarily" do
    runtime
    NestedPieces::Workspace.open!(reference: { value: "W1" })
    NestedPieces::Workspace.find("W1").add_board!(number: { value: 1 })
    runtime.dispatch_flat("NestedPieces::Workspace.Board.AddCard",
                          to: { aggregate: "W1", entity: "1" }, sequence: { value: 1 })

    runtime.dispatch_flat("NestedPieces::Workspace.Board.Label",
                          to: { aggregate: "W1", entity: "1" }, label: { value: "Sprint 1" })
    runtime.dispatch_flat("NestedPieces::Workspace.Board.Card.Annotate",
                          to:   { aggregate: "W1", entities: ["1", "1"] },
                          note: { text: "done" })

    workspace = NestedPieces::Workspace.find("W1")
    board = workspace[:boards].find { |b| b[:number][:value] == 1 }
    expect(board[:label][:value]).to eq("Sprint 1")
    expect(board[:cards].first[:note][:text]).to eq("done")
  end

  # Hop one: `board.number` is nonexistent and fails its invariant, yet must answer NotFound.
  # Flat addressing on purpose: `to:` matches by raw string and never coerces the identity.
  it "answers NotFound for a board number that fails its own invariant, not InvariantViolation" do
    runtime
    NestedPieces::Workspace.open!(reference: { value: "W1" })

    expect do
      runtime.dispatch_flat("NestedPieces::Workspace.Board.Label",
                            reference: { value: "W1" }, number: { value: 0 }, label: { value: "Sprint 1" })
    end.to raise_error(Hecks::Runtime::NotFound, /number\.value 0/)
  end

  # Hop two: same as hop one one level deeper; the fix is per-hop in `locate_chain`.
  it "answers NotFound for a card sequence that fails its own invariant, not InvariantViolation, two hops deep" do
    runtime
    NestedPieces::Workspace.open!(reference: { value: "W1" })
    NestedPieces::Workspace.find("W1").add_board!(number: { value: 1 })

    expect do
      runtime.dispatch_flat("NestedPieces::Workspace.Board.Card.Annotate",
                            reference: { value: "W1" }, number: { value: 1 }, sequence: { value: 0 },
                            note: { text: "ghost" })
    end.to raise_error(Hecks::Runtime::NotFound, /sequence\.value 0/)
  end
end
