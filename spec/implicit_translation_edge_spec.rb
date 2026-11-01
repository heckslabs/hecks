require "hecks"
require "hecks/ports/persistence/plugins/era"
require "json"
require "tmpdir"
require_relative "../lib/hecks/adapters/driven/postgres_era/lineage_manager"

# The implicit empty edge: a shape change whose scaffold finds no rule, no retirement and no
# unresolved name, and only adds, needs no edge file. Every other change still refuses toward the
# scaffold, and an implicit edge goes through the same audit as a written one.
module ImplicitEdgeSupport
  MEMO_TYPE = "value_object \"Memo\" do\n      attribute :text, String\n    end".freeze
  OPTIONAL_MEMO = "attribute :memo, Memo, optional: true\n    #{MEMO_TYPE}".freeze
  REQUIRED_MEMO = "attribute :memo, Memo\n    #{MEMO_TYPE}".freeze
  Ctx = Struct.new(:registry, :bluebook, :latest, :label, :domain_name, :ordinal, :directory) do
    # The ledger watermark the decision reads; the ledger has no era past this one.
    def watermark = 1
  end
  # A lineage that answers the audit's reads with nothing and keeps the fields of a mint.
  class FakeLineage
    attr_reader :minted

    def translated_latest(*) = {}
    def split_latest(*) = {}
    def ancestor_latest(*) = {}
    def received_latest(*) = {}

    def mint_era!(**fields) = @minted = fields
  end

  Commit = Struct.new(:bluebook, :current_text, :lineage, :role, :ordinal) do
    def shape_hash = Hecks::Runtime::StorageShape.mint_hash(bluebook)
  end

  # @return [String] a ledger bluebook with `cost` (or a renamed field) and optional extra lines
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

  def declared(text) = Hecks::Adapters::PostgresEra::LineageManager.shadow(text)

  def diff_for(held_text, current_text)
    Hecks::Translation::Scaffold.diff(declared(held_text), declared(current_text))
  end

  # The implicit edge the shared decision takes, with the move the shape ledger records.
  def implicit_for(held_text, current_text)
    decision = Hecks::Adapters::PostgresEra::LineageManager::MintDecision
    bluebook = declared(current_text)
    recorded = [["aaaaaa", decision.label_of(bluebook)]]
    held = { ordinal: 1, label: "aaaaaa", held_text: held_text, declaration: declared(held_text) }
    verdict = decision.decide(held: [held], bluebook: bluebook, watermark: 1, rows: [],
                              edge_source: { translations: [], recorded: recorded })
    verdict.edge if verdict.verdict == "would_mint"
  end

  def implicit(held_text) = implicit_for(held_text, ledger_text(extra: ImplicitEdgeSupport::OPTIONAL_MEMO))

  def registry = Struct.new(:translations).new([])

  # The era check's context, for the minter's edge resolution.
  def resolve_edge(held_text, current_text, directory: nil)
    ctx = Ctx.new(registry, declared(current_text), { ordinal: 1, label: "aaaaaa", held_text: held_text },
                  "bbbbbb", "Ledger", 2, directory)
    host.resolve_edge!(ctx)
  end

  # Writes the implicit move the shape ledger records for `current_text`, from the held label.
  def record_implicit(directory, current_text)
    label = Hecks::Runtime::StorageShape.mint_hash(declared(current_text))[0, Hecks::Runtime::StorageShape::LABEL_LENGTH]
    moves = { "Ledger" => [{ "from" => "aaaaaa", "to" => label }] }
    File.write(File.join(directory, Hecks::ShapeLedger::IMPLICIT_FILE), JSON.generate(moves))
  end

  # An object carrying every part of the lineage manager a minter path calls.
  def host
    manager = Hecks::Adapters::PostgresEra::LineageManager
    Object.new.extend(manager, manager::Minter, manager::CoverageCheck)
  end

  def audit(edge)
    bluebook = Struct.new(:name, :aggregates).new("Ledger", [Struct.new(:name).new("Acct")])
    lineage = FakeLineage.new
    host.audit!(bluebook, lineage, [{ translation: edge }], 2, edge)
  end

  # The chain from the held era to the era a step reaches, which the journal names by `target`.
  def chain_over(target)
    Hecks::Adapters::PostgresEra::LineageManager.edge_chain(registry, declared(ledger_text), [held_era], "bbbbbb",
                                                            target: target)
  end

  def held_era = { ordinal: 1, label: "aaaaaa" }
end

RSpec.describe "an implicit translation edge" do
  include ImplicitEdgeSupport

  let(:held_text) { ledger_text }

  # The label of the bluebook that adds the optional memo, which the implicit edge reaches.
  def optional_label
    Hecks::Adapters::PostgresEra::LineageManager::MintDecision.label_of(
      declared(ledger_text(extra: ImplicitEdgeSupport::OPTIONAL_MEMO))
    )
  end

  it "is the edge a shape change that only adds carries", :aggregate_failures do
    edge = implicit_for(held_text, ledger_text(extra: ImplicitEdgeSupport::OPTIONAL_MEMO))

    expect(edge).to be_a(Hecks::Translation::ImplicitEdge)
    expect([edge.from, edge.to, edge.implicit?]).to eq(["aaaaaa", optional_label, true])
  end

  it "takes no part in an aggregate's rules and names none", :aggregate_failures do
    edge = implicit(held_text)

    expect(edge.aggregates).to eq([])
    expect(edge.for_aggregate("Acct")).to be_nil
  end

  it "does not qualify a rename, which needs a rule", :aggregate_failures do
    renamed = ledger_text(cost: "amount")

    expect(implicit_for(held_text, renamed)).to be_nil
    expect(Hecks::Translation::ImplicitEdge.qualifies?(diff_for(held_text, renamed), declared(held_text),
                                                       declared(renamed))).to be(false)
  end

  it "does not qualify a required attribute an existing aggregate gained" do
    expect(implicit_for(held_text, ledger_text(extra: ImplicitEdgeSupport::REQUIRED_MEMO))).to be_nil
  end

  it "still refuses toward the scaffold when the change has a rule" do
    expect { resolve_edge(held_text, ledger_text(cost: "amount")) }
      .to raise_error(Hecks::Runtime::WiringError, /no translation edge covers it/)
  end

  it "resolves a change that only adds to an implicit edge" do
    current = ledger_text(extra: ImplicitEdgeSupport::OPTIONAL_MEMO)

    Dir.mktmpdir do |dir|
      record_implicit(dir, current)
      expect(resolve_edge(held_text, current, directory: dir)).to be_a(Hecks::Translation::ImplicitEdge)
    end
  end

  it "still fails the audit when the audit finds a violation" do
    allow(Hecks::Translation::Audit).to receive(:check).and_return(Struct.new(:violations).new(["row 1 lost"]))

    expect { audit(implicit(held_text)) }.to raise_error(Hecks::Runtime::WiringError, /the audit refused/)
  end

  it "reads an era minted under an implicit edge back as an implicit step of the chain" do
    record = { ordinal: 2, label: "bbbbbb", edge: Hecks::Translation::ImplicitEdge::RECORD }
    expect(chain_over(record).first[:translation]).to be_a(Hecks::Translation::ImplicitEdge)
  end

  it "refuses a chain step that no file and no journal record leads to" do
    expect { chain_over(nil) }
      .to raise_error(Hecks::Runtime::WiringError, /edge chain is broken/)
  end

  it "records the era it minted as implicit" do
    lineage = ImplicitEdgeSupport::FakeLineage.new
    current = ledger_text(extra: ImplicitEdgeSupport::OPTIONAL_MEMO)
    context = ImplicitEdgeSupport::Commit.new(declared(current), current, lineage, nil, 2)

    host.send(:commit_era!, context, [], implicit(held_text))

    expect(lineage.minted).to include(edge: Hecks::Translation::ImplicitEdge::RECORD)
  end
end
