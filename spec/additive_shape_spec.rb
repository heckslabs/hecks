require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../lib/hecks/adapters/driven/postgres_era/lineage_manager"

# Whether a change to an aggregate's storage shape only adds, asked three ways that must agree:
# the implicit edge's rule, the shared shape rule over a held declaration, and the disposable
# ledger's classification over a held projection. A pair that is not plainly additive is breaking.
RSpec.describe Hecks::Translation::AdditiveShape do
  def source(attrs, identity: "kind", lifecycle: "")
    <<~BLUEBOOK
      Hecks.bluebook "Ledger" do
        aggregate "Acct" do
          identified_by :#{identity}
          attribute :kind, Kind
          attribute :status, String, optional: true
          #{attrs}
          #{lifecycle}
          value_object("Kind") { attribute :label, String }
          value_object("Nm") { attribute :value, String }
          value_object("Qty") { attribute :count, Integer }
        end
      end
    BLUEBOOK
  end

  def declared(text) = Hecks::Adapters::PostgresEra::LineageManager.shadow(text)

  def implicit?(held, current)
    diff = Hecks::Translation::Scaffold.diff(declared(held), declared(current))
    Hecks::Translation::ImplicitEdge.qualifies?(diff, declared(held), declared(current))
  end

  def shared?(held, current) = described_class.additive?(declared(held), declared(current))

  def ledger?(held, current)
    projection = Hecks::Runtime::StorageShape.project(declared(held))
    change = Hecks::Adapters::PostgresEra::LineageManager::LedgerChange.between(projection, declared(current))
    change.replaced.empty?
  end

  LIFE = lambda do |field, *states|
    moves = states.drop(1).map { |state| %(transition "To#{state}" => "#{state}") }.join("\n")
    %(lifecycle :#{field}, default: "#{states.first}" do\n#{moves}\nend)
  end
  def life(*args) = LIFE.call(*args)

  NM = "attribute :n, Nm".freeze
  OPT_M = "#{NM}\nattribute :m, Nm, optional: true".freeze
  REQ_M = "#{NM}\nattribute :m, Nm".freeze
  PHASE = "#{NM}\nattribute :phase, String, optional: true".freeze

  # Each pair: the held attributes and options, the booting ones, and whether the change only adds.
  PAIRS = {
    "an unchanged shape"                       => [[NM, {}], [NM, {}], true],
    "an optional attribute gained"             => [[NM, {}], [OPT_M, {}], true],
    "a required attribute gained"              => [[NM, {}], [REQ_M, {}], false],
    "a scalar flipped to a list, same members" => [[NM, {}], ["attribute :n, list_of(Nm)", {}], false],
    "a list flipped to a scalar"               => [["attribute :n, list_of(Nm)", {}], [NM, {}], false],
    "a member retyped"                         => [[NM, {}], ["attribute :n, Qty", {}], false],
    "an attribute dropped"                     => [[NM, {}], ["", {}], false],
    "an attribute renamed"                     => [[NM, {}], ["attribute :q, Nm", {}], false],
    "the identity changed"                     => [[NM, {}], [NM, { identity: "n" }], false],
    "a lifecycle field added"                  => [[NM, {}], [NM, { lifecycle: LIFE.call(:status, "a", "b") }], false],
    "a lifecycle field renamed"                => [[PHASE, { lifecycle: LIFE.call(:status, "a", "b") }],
                                                   [PHASE, { lifecycle: LIFE.call(:phase, "a", "b") }], false]
  }.freeze

  PAIRS.each do |name, (held, current, additive)|
    verdict = additive ? "additive" : "breaking"

    %i[implicit? shared? ledger?].zip(["the implicit edge", "the shared rule", "the disposable ledger"]).each do |ask, by|
      it "calls #{name} #{verdict} by #{by}" do
        expect(send(ask, source(held[0], **held[1]), source(current[0], **current[1]))).to be(additive)
      end
    end
  end

  describe "what only a held declaration can tell" do
    it "calls an optional attribute made required breaking" do
      held = source("attribute :n, Nm, optional: true")
      expect(shared?(held, source("attribute :n, Nm"))).to be(false)
    end

    it "calls a removed lifecycle state breaking" do
      held = source("attribute :n, Nm", lifecycle: LIFE.call(:status, "a", "b", "c"))
      expect(shared?(held, source("attribute :n, Nm", lifecycle: LIFE.call(:status, "a", "b")))).to be(false)
    end

    it "calls an added lifecycle state additive" do
      held = source("attribute :n, Nm", lifecycle: LIFE.call(:status, "a", "b"))
      expect(shared?(held, source("attribute :n, Nm", lifecycle: LIFE.call(:status, "a", "b", "c")))).to be(true)
    end

    it "cannot see an optional attribute made required between two projections" do
      held = Hecks::Runtime::StorageShape.project(declared(source("attribute :n, Nm, optional: true")))
      expect(described_class.additive?(held, declared(source("attribute :n, Nm")))).to be(true)
    end
  end

  describe "the implicit edge's decision with a recorded move" do
    def verdict(held_text, current_text)
      decision = Hecks::Adapters::PostgresEra::LineageManager::MintDecision
      bluebook = declared(current_text)
      held = { ordinal: 1, label: "aaaaaa", held_text: held_text, declaration: declared(held_text) }
      decision.decide(held: [held], bluebook: bluebook, watermark: 1, rows: [],
                      edge_source: { translations: [], recorded: [["aaaaaa", decision.label_of(bluebook)]] }).verdict
    end

    it "mints nothing for a scalar flipped to a list of the same value object" do
      expect(verdict(source("attribute :n, Nm"), source("attribute :n, list_of(Nm)"))).to eq("needs_edge")
    end

    it "still mints an implicit edge for an optional attribute gained" do
      expect(verdict(source(NM), source(OPT_M))).to eq("would_mint")
    end
  end
end
