require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../lib/hecks/adapters/driven/postgres_era/lineage_manager"
require_relative "../lib/hecks/hecks/adapters/model_change_kind"

# The kind a storage-shape change is, read from the same `LedgerChange` the mint judges, so a
# review and the mint agree on what is breaking.
RSpec.describe Hecks::Adapters::ModelChangeKind do
  KindChange = Struct.new(:added, :widened, :replaced)

  def source(attrs, extra: "")
    <<~BLUEBOOK
      Hecks.bluebook "Ledger" do
        aggregate "Acct" do
          identified_by :n
          #{attrs}
          value_object("Nm") { attribute :value, String }
        end
        #{extra}
      end
    BLUEBOOK
  end

  def declared(text) = Hecks::Adapters::PostgresEra::LineageManager.shadow(text)

  def kind_between(held, current, extra: "")
    projection = Hecks::Runtime::StorageShape.project(declared(source(held)))
    change = Hecks::Adapters::PostgresEra::LineageManager::LedgerChange.between(projection,
                                                                                declared(source(current, extra: extra)))
    described_class.of(change)
  end

  HELD_NM = "attribute :n, Nm".freeze
  HELD_OPT = "#{HELD_NM}\nattribute :m, Nm, optional: true".freeze
  ADDED_AGG = %(aggregate "Other" do\n identified_by :n\n attribute :n, String\n end).freeze

  it "calls an unchanged shape no shape change" do
    expect(kind_between(HELD_NM, HELD_NM)).to eq(:no_shape_change)
  end

  it "calls a gained optional attribute additive" do
    expect(kind_between(HELD_NM, HELD_OPT)).to eq(:additive)
  end

  it "calls a gained aggregate additive" do
    expect(kind_between(HELD_NM, HELD_NM, extra: ADDED_AGG)).to eq(:additive)
  end

  it "calls a dropped attribute breaking" do
    expect(kind_between(HELD_OPT, HELD_NM)).to eq(:breaking)
  end

  it "lets a replaced aggregate win over an added one" do
    expect(described_class.of(KindChange.new(["B"], [], ["A"]))).to eq(:breaking)
  end

  it "lets a widened aggregate with an added one stay additive" do
    expect(described_class.of(KindChange.new(["B"], ["A"], []))).to eq(:additive)
  end
end
