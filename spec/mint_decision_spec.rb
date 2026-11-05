require "hecks"
require "hecks/ports/persistence/plugins/era"
require "json"
require "tmpdir"
require_relative "../lib/hecks/adapters/driven/postgres_era/lineage_manager"

# The one mint decision the rehearsal and the mint share. Each example gives the decision the same
# inputs a caller would, on disposable bluebooks and a fake lineage, with no database.
module MintDecisionSupport
  Manager = Hecks::Adapters::PostgresEra::LineageManager
  Decision = Manager::MintDecision
  MEMO = "attribute :memo, Memo, optional: true\n    value_object \"Memo\" do\n      attribute :text, String\n    end".freeze
  Ctx = Struct.new(:registry, :bluebook, :latest, :label, :domain_name, :ordinal, :directory) do
    # The ledger watermark the decision reads in these examples.
    def watermark = 1
  end

  # A lineage whose ledger watermark moves while the audit reads it, as a write landing between the
  # decision and the write would. It writes nothing.
  class MovingLineage
    def initialize(held)
      @held = held
      @watermark = 1
    end

    def eras = [@held]

    def last_ordinal = @watermark

    def translated_latest(*)
      @watermark = 2
      {}
    end

    def split_latest(*) = {}

    def ancestor_latest(*) = {}

    def received_latest(*) = {}

    def mint_era!(**) = raise("a refused mint must not write an era")
  end

  # @return [String] a ledger bluebook with `cost` and optional extra lines
  def ledger_text(cost: "cost", extra: "")
    <<~RUBY
      Hecks.bluebook "Ledger" do
        aggregate "Acct" do
          identified_by :kind
          attribute :#{cost}, Money
          attribute :kind, Kind
          #{extra}
          value_object "Money" do
            attribute :cents, Integer
          end
          value_object "Kind" do
            attribute :label, String
          end
        end
      end
    RUBY
  end

  def optional_current = ledger_text(extra: MEMO)

  def renamed_current = ledger_text(cost: "amount")

  def declared(text) = Manager.shadow(text)

  def label_of(text) = Decision.label_of(declared(text))

  def held_era(text)
    { ordinal: 1, label: "aaaaaa", held_text: text, declaration: declared(text),
      projection: Hecks::Runtime::StorageShape.project(declared(text)) }
  end

  def registry = Struct.new(:translations).new([])

  # The verdict for one held era against one current bluebook, with the recorded moves given.
  def decide(held_text, current_text, recorded: [])
    Decision.decide(held: [held_era(held_text)], bluebook: declared(current_text),
                    edge_source: { translations: [], recorded: recorded }, watermark: 1, rows: [])
  end

  def recorded_to(current_text) = [["aaaaaa", label_of(current_text)]]

  # Writes the implicit move the shape ledger records for `current_text` into `directory`.
  def record_implicit(directory, current_text)
    moves = { "Ledger" => [{ "from" => "aaaaaa", "to" => label_of(current_text) }] }
    File.write(File.join(directory, Hecks::ShapeLedger::IMPLICIT_FILE), JSON.generate(moves))
  end

  def with_recorded(current_text)
    Dir.mktmpdir do |dir|
      record_implicit(dir, current_text)
      yield dir
    end
  end

  # The edge the minter's resolution settles on for the same change, or the refusal it raises.
  def resolve_for(held_text, current_text, directory: nil)
    ctx = Ctx.new(registry, declared(current_text), held_era(held_text).merge(hash: "aaaaaa"),
                  label_of(current_text), "Ledger", 2, directory)
    Object.new.extend(Manager, Manager::HeldRevision, Manager::Minter, Manager::CoverageCheck).resolve_edge!(ctx)
  end

  # Runs the mint's own check over a lineage that moves between its decision and its write.
  def mint_over(lineage, current_text, directory)
    context = Manager::Context.new(
      registry: registry, bluebook: declared(current_text), current_text: current_text, lineage: lineage,
      role: nil, directory: directory, latest: held_era(ledger_text).merge(hash: "aaaaaa"),
      mint_permitted: true, mint_request: Manager::MintRequest.new(confirm: true, verdict: "would_mint", watermark: 1)
    )
    Object.new.extend(Manager, Manager::HeldRevision, Manager::Minter, Manager::CoverageCheck).mint!(context)
  end

  def rename_verdict = decide(ledger_text, renamed_current, recorded: recorded_to(renamed_current))

  def expect_scaffold_refusal(directory)
    expect { resolve_for(ledger_text, renamed_current, directory: directory) }
      .to raise_error(Hecks::Runtime::WiringError, /no translation edge covers it/)
  end

  def minted_class(directory) = resolve_for(ledger_text, optional_current, directory: directory).class

  def snapshot(directory) = Dir.glob(File.join(directory, "**", "*")).map { |path| [path, File.read(path)] }
end

RSpec.describe "the mint decision the rehearsal and the mint share" do
  include MintDecisionSupport

  it "would mint an additive move that a recorded implicit move names", :aggregate_failures do
    verdict = decide(ledger_text, optional_current, recorded: recorded_to(optional_current))

    expect([verdict.verdict, verdict.source, verdict.edge.to]).to eq(["would_mint", "implicit", label_of(optional_current)])
  end

  it "needs an edge for an additive move no record names", :aggregate_failures do
    verdict = decide(ledger_text, optional_current)

    expect([verdict.verdict, verdict.reason, verdict.edge]).to eq(["needs_edge", :unrecorded, nil])
  end

  it "needs an edge for a rename without a rule, and carries the diff", :aggregate_failures do
    verdict = decide(ledger_text, renamed_current, recorded: recorded_to(renamed_current))

    expect([verdict.verdict, verdict.reason, verdict.diff[:aggregates].empty?]).to eq(["needs_edge", :non_qualifying, false])
  end

  it "refuses a non-qualifying implicit move the same way on both paths", :aggregate_failures do
    expect(rename_verdict.reason).to eq(:non_qualifying)
    with_recorded(renamed_current) { |dir| expect_scaffold_refusal(dir) }
  end

  it "gives the rehearsal and the mint the same edge for one additive change", :aggregate_failures do
    with_recorded(optional_current) do |dir|
      rehearsal = decide(ledger_text, optional_current, recorded: MintDecisionSupport::Decision.recorded_moves("Ledger", dir))
      expect([rehearsal.verdict, rehearsal.edge.class]).to eq(["would_mint", minted_class(dir)])
    end
  end

  it "writes nothing: the directory holds the same files and bytes after a decision", :aggregate_failures do
    with_recorded(optional_current) do |dir|
      before = snapshot(dir)
      decide(ledger_text, optional_current, recorded: MintDecisionSupport::Decision.recorded_moves("Ledger", dir))
      expect(snapshot(dir)).to eq(before)
    end
  end

  it "refuses a watermark that moved between the decision and the write, by name" do
    with_recorded(optional_current) do |dir|
      expect { mint_over(MintDecisionSupport::MovingLineage.new(held_era(ledger_text).merge(hash: "aaaaaa")), optional_current, dir) }
        .to raise_error(Hecks::Runtime::WiringError, /the ledger watermark moved from 1 to 2 since the rehearsal/)
    end
  end
end
