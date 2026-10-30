require "spec_helper"

# Two-level nested pieces (Board, Card) from qa/stress_domains/nested_pieces.
# Pins NotFound, not InvariantViolation, for an address failing its own invariant at both hops.
RSpec.describe "NestedPieces" do
  NESTED_PIECES_ROOT = File.join(InMemoryDomain::ROOT, "qa/stress_domains/nested_pieces/bluebook").freeze

  def declare_workspace_hexagon
    Hecks.hecksagon "NestedPieces" do
      attaches "Governance"

      NestedPieces::Workspace.persisted_by("Memory")
    end
  end

  def boot_nested_pieces
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
       InMemoryDomain::PRISM_ADAPTER, File.join(NESTED_PIECES_ROOT, "nested_pieces.bluebook")].each { |file| Kernel.load(file) }
      declare_workspace_hexagon
      sibling_governance!
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let(:runtime) { boot_nested_pieces }

  def open_workspace
    runtime
    NestedPieces::Workspace.open!(reference: { value: "W1" })
  end

  def workspace_with_board
    open_workspace
    NestedPieces::Workspace.find("W1").add_board!(number: { value: 1 })
  end

  def workspace_with_card
    workspace_with_board
    runtime.dispatch_flat("NestedPieces::Workspace.Board.AddCard",
                          to: { aggregate: "W1", entity: "1" }, sequence: { value: 1 })
  end

  def board_one = NestedPieces::Workspace.find("W1")[:boards].find { |b| b[:number][:value] == 1 }

  # An appended entity must store a key for every declared attribute, unset ones as nil,
  # matching Rust's `to_json`, which always emits every declared field.
  it "gives a freshly appended Board a key for every declared attribute, unset ones included", :aggregate_failures do
    workspace_with_card
    board = board_one

    expect(board.key?(:label)).to be(true)
    expect(board[:label]).to be_nil
  end

  it "gives a freshly appended Card a key for every declared attribute, unset ones included", :aggregate_failures do
    workspace_with_card
    card = board_one[:cards].first

    expect(card.key?(:note)).to be(true)
    expect(card[:note]).to be_nil
  end

  it "opens a workspace, adds a board, and adds a card two levels deep" do
    workspace_with_card

    expect(board_one[:cards].map { |card| card[:sequence][:value] }).to eq([1])
  end

  it "labels a board two levels deep, ordinarily" do
    workspace_with_card
    runtime.dispatch_flat("NestedPieces::Workspace.Board.Label",
                          to: { aggregate: "W1", entity: "1" }, label: { value: "Sprint 1" })

    expect(board_one[:label][:value]).to eq("Sprint 1")
  end

  it "annotates a card two levels deep, ordinarily" do
    workspace_with_card
    runtime.dispatch_flat("NestedPieces::Workspace.Board.Card.Annotate",
                          to:   { aggregate: "W1", entities: ["1", "1"] },
                          note: { text: "done" })

    expect(board_one[:cards].first[:note][:text]).to eq("done")
  end

  def label_board_zero
    runtime.dispatch_flat("NestedPieces::Workspace.Board.Label",
                          reference: { value: "W1" }, number: { value: 0 }, label: { value: "Sprint 1" })
  end

  # Hop one: `board.number` is nonexistent and fails its invariant, yet must answer NotFound.
  # Flat addressing on purpose: `to:` matches by raw string and never coerces the identity.
  it "answers NotFound for a board number that fails its own invariant, not InvariantViolation" do
    open_workspace

    expect { label_board_zero }.to raise_error(Hecks::Runtime::NotFound, /number\.value 0/)
  end

  def annotate_ghost_card
    runtime.dispatch_flat("NestedPieces::Workspace.Board.Card.Annotate",
                          reference: { value: "W1" }, number: { value: 1 }, sequence: { value: 0 },
                          note: { text: "ghost" })
  end

  # Hop two: same as hop one one level deeper; the fix is per-hop in `locate_chain`.
  it "answers NotFound for a card sequence that fails its own invariant, not InvariantViolation, two hops deep" do
    workspace_with_board

    expect { annotate_ghost_card }.to raise_error(Hecks::Runtime::NotFound, /sequence\.value 0/)
  end
end
