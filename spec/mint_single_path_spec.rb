require "hecks"
require "hecks/ports/persistence/plugins/era"
require "json"
require "tmpdir"
require_relative "../lib/hecks/adapters/driven/postgres_era/lineage_manager"

# The single mint path: the shared decision names the edge a mint takes, derived from the diff when
# the change needs no rule, and refuses a rename without a rule; only an edge to the current shape
# counts, so other edges from the held era neither fork it nor make it stale. Each example
# uses disposable bluebook text and no database.
module SinglePathSupport
  Decision = Hecks::Adapters::PostgresEra::LineageManager::MintDecision
  HELD_LABEL = "aaaaaa".freeze
  MEMO = "attribute :memo, Memo, optional: true\n    value_object \"Memo\" do\n      attribute :text, String\n    end".freeze
  Edge = Struct.new(:domain, :from, :to)

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

  def declared(text) = Hecks::Adapters::PostgresEra::LineageManager.shadow(text)

  def label_of(text) = Decision.label_of(declared(text))

  # A held era as the journal stores it: its text, and the storage shape its mint recorded.
  def held_era(text)
    { ordinal: 1, label: HELD_LABEL, held_text: text, projection: Hecks::Runtime::StorageShape.project(declared(text)) }
  end

  # The verdict the decision reaches for one held era, with the recorded moves and edges given.
  def decide(held_text, current_text, recorded: [], translations: [])
    Decision.decide(held: [held_era(held_text).merge(declaration: declared(held_text))],
                    bluebook: declared(current_text), watermark: 1, rows: [],
                    edge_source: { translations: translations, recorded: recorded })
  end

  # The verdict of the entry point that reads the recorded moves from a directory it is given.
  def decide_from_directory
    Dir.mktmpdir do |dir|
      record_moves(dir, [{ "from" => HELD_LABEL, "to" => label_of(optional_current) }])
      Decision.decide_latest(held_era(ledger_text), bluebook: declared(optional_current),
                                                    translations: [], directory: dir, watermark: 1)
    end
  end

  # Writes the implicit moves the shape ledger records into `directory`, as the framework does.
  def record_moves(directory, moves)
    File.write(File.join(directory, Hecks::ShapeLedger::IMPLICIT_FILE), JSON.generate("Ledger" => moves))
  end
end

RSpec.describe "the single mint path" do
  include SinglePathSupport

  it "mints a no-rule additive diff with a derived edge", :aggregate_failures do
    verdict = decide(ledger_text, optional_current, recorded: [[SinglePathSupport::HELD_LABEL, label_of(optional_current)]])
    expect(verdict.verdict).to eq("would_mint")
    expect(verdict.source).to eq("implicit")
    expect(verdict.edge).to be_a(Hecks::Translation::ImplicitEdge)
  end

  it "reaches the derived edge through the entry point that reads the recorded moves" do
    expect(decide_from_directory).to have_attributes(verdict: "would_mint", source: "implicit")
  end

  it "refuses a rename without a rule toward the scaffold", :aggregate_failures do
    verdict = decide(ledger_text, renamed_current, recorded: [[SinglePathSupport::HELD_LABEL, label_of(renamed_current)]])
    expect(verdict).to have_attributes(verdict: "needs_edge", reason: :non_qualifying)
  end

  it "refuses an additive move that no recorded implicit move reaches" do
    expect(decide(ledger_text, optional_current)).to have_attributes(verdict: "needs_edge", reason: :unrecorded)
  end

  it "takes the edge to the shape beside a self-loop edge, which leads nowhere new" do
    target = SinglePathSupport::Edge.new("Ledger", SinglePathSupport::HELD_LABEL, label_of(optional_current))
    loop_edge = SinglePathSupport::Edge.new("Ledger", SinglePathSupport::HELD_LABEL, SinglePathSupport::HELD_LABEL)
    expect(decide(ledger_text, optional_current, translations: [loop_edge, target]))
      .to have_attributes(verdict: "would_mint", source: "file")
  end

  it "decides by the diff beside a lone self-loop edge, since it does not reach the shape" do
    loop_edge = SinglePathSupport::Edge.new("Ledger", SinglePathSupport::HELD_LABEL, SinglePathSupport::HELD_LABEL)
    expect(decide(ledger_text, optional_current, translations: [loop_edge]))
      .to have_attributes(verdict: "needs_edge", reason: :unrecorded)
  end
end
