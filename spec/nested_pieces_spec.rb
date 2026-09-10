require "spec_helper"

# qa/stress_domains/nested_pieces — see its own NOTES.md and the header
# comment on nested_pieces.bluebook for why this domain exists: a genuine
# two-level "piece nested inside a piece" (ADR 0026), unexercised anywhere
# else in the fuzzed corpus, used to confirm BUG#3's fix (PR #526, merged
# as of this domain's own PR) generalizes to a hop this corpus had never
# actually reached before. BUG#3 was an addressing identity that failed
# its own invariant raising InvariantViolation instead of NotFound; these
# two tests assert the FIXED behavior (NotFound) at BOTH hop one (Board)
# and hop two (Card) — a regression pin, not an open-bug demonstration.
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
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let(:runtime) { boot_nested_pieces }

  it "opens a workspace, adds a board, and adds a card two levels deep" do
    runtime
    NestedPieces::Workspace.open!(reference: { value: "W1" })
    NestedPieces::Workspace.find("W1").add_board!(number: { value: 1 })

    runtime.dispatch("NestedPieces::Workspace.Board.AddCard",
                     to: { aggregate: "W1", entity: "1" }, sequence: { value: 1 })

    workspace = NestedPieces::Workspace.find("W1")
    board = workspace[:boards].find { |b| b[:number][:value] == 1 }
    expect(board[:cards].map { |card| card[:sequence][:value] }).to eq([1])
  end

  it "labels a board and annotates a card two levels deep, ordinarily" do
    runtime
    NestedPieces::Workspace.open!(reference: { value: "W1" })
    NestedPieces::Workspace.find("W1").add_board!(number: { value: 1 })
    runtime.dispatch("NestedPieces::Workspace.Board.AddCard",
                     to: { aggregate: "W1", entity: "1" }, sequence: { value: 1 })

    runtime.dispatch("NestedPieces::Workspace.Board.Label",
                     to: { aggregate: "W1", entity: "1" }, label: { value: "Sprint 1" })
    runtime.dispatch("NestedPieces::Workspace.Board.Card.Annotate",
                     to:   { aggregate: "W1", entities: ["1", "1"] },
                     note: { text: "done" })

    workspace = NestedPieces::Workspace.find("W1")
    board = workspace[:boards].find { |b| b[:number][:value] == 1 }
    expect(board[:label][:value]).to eq("Sprint 1")
    expect(board[:cards].first[:note][:text]).to eq("done")
  end

  # HOP ONE — the same single-level shape BUG#3 was originally found on
  # (`Banking::Account.LedgerEntry.Amend`), re-triggered here: `board.number`
  # is both nonexistent (the workspace holds no boards at all) AND fails
  # `BoardNumber`'s own invariant (`0`, never positive). Post-fix, this
  # answers `NotFound` — the same refusal a valid-shaped but nonexistent
  # number already gets, not `InvariantViolation`.
  #
  # FLAT, LEGACY-STYLE ADDRESSING ON PURPOSE, NOT `to:` — this is the
  # exact shape that matters, still, even fixed. `to: { entities: [...]
  # }` resolves through `Routing::Envelope` into `route.entities`, which
  # `EntityElement#element_of` matches by RAW STRING (`element_identity(
  # ...).to_s == routed_identity.to_s`, no typed rebuild, no invariant
  # ever consulted) — was already immune to BUG#3 even before the fix,
  # the same raw-comparison convention `Identity.from` uses for a root
  # aggregate. The original finding (and the original `LedgerEntry.
  # Reverse` spec) dispatches with the entity's own identity riding as a
  # flat ARGUMENT instead (`sequence: { value: 0 }`, no `to:` at all) —
  # THAT is the path `wants = entity.identity_paths.map { ... }` builds
  # from `args[head]`, coercing (invariant included, pre-fix; degraded to
  # `UNMATCHABLE` post-fix) before any existence check runs.
  it "answers NotFound for a board number that fails its own invariant, not InvariantViolation" do
    runtime
    NestedPieces::Workspace.open!(reference: { value: "W1" })

    expect do
      runtime.dispatch("NestedPieces::Workspace.Board.Label",
                       reference: { value: "W1" }, number: { value: 0 }, label: { value: "Sprint 1" })
    end.to raise_error(Hecks::Runtime::NotFound, /number\.value 0/)
  end

  # HOP TWO — THE WHOLE REASON THIS DOMAIN EXISTS. `card.sequence` is both
  # nonexistent (the board holds no cards at all) AND fails `CardSequence`'s
  # own invariant (`0`, never positive) — one hop deeper than BUG#3's own
  # fix had ever actually been confirmed at before this domain existed.
  # `EntityElement#element_of` is called once per hop by `locate_chain`,
  # so the fix (degrading a coercion failure to `UNMATCHABLE` rather than
  # propagating `InvariantViolation`) is architecturally hop-depth-
  # agnostic — this is the test that actually PROVES that, rather than
  # assumes it. Flat addressing again, for the same reason the hop-one
  # case above needs it.
  it "answers NotFound for a card sequence that fails its own invariant, not InvariantViolation, two hops deep" do
    runtime
    NestedPieces::Workspace.open!(reference: { value: "W1" })
    NestedPieces::Workspace.find("W1").add_board!(number: { value: 1 })

    expect do
      runtime.dispatch("NestedPieces::Workspace.Board.Card.Annotate",
                       reference: { value: "W1" }, number: { value: 1 }, sequence: { value: 0 },
                       note: { text: "ghost" })
    end.to raise_error(Hecks::Runtime::NotFound, /sequence\.value 0/)
  end
end
