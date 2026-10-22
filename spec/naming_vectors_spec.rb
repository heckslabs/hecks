require "spec_helper"
require "hecks/ports/persistence/plugins/era/postgres_era/lineage"

# Hecks::Naming and Lineage#qualified_name have Rust twins: rust/codegen/src/hecks_naming.rs (the one
# port of Naming, compiled into the parser, build, host and kernel crates) and the host's journal.rs.
# spec/fixtures/naming_vectors.json is the one table both sides assert, so a drift in either
# fails a test on its own side.
RSpec.describe "the shared naming vectors" do
  NAMING_VECTORS = JSON.parse(File.read(File.join(InMemoryDomain::ROOT, "spec", "fixtures", "naming_vectors.json")))

  def qualified_name(domain, suffix)
    Hecks::Adapters::PostgresEra::Lineage.new(nil, domain).send(:qualified_name, suffix)
  end

  NAMING_VECTORS.fetch("snake").each do |row|
    it "Naming.snake(#{row["input"].inspect}) is #{row["expected"].inspect}" do
      expect(Hecks::Naming.snake(row["input"])).to eq(row["expected"])
    end
  end

  {
    "pascal" => :pascal, "plural" => :plural, "singularize" => :singularize,
    "demodulise" => :demodulise, "reference_key" => :reference_key
  }.each do |table, rule|
    NAMING_VECTORS.fetch(table).each do |row|
      it "Naming.#{rule}(#{row["input"].inspect}) is #{row["expected"].inspect}" do
        expect(Hecks::Naming.public_send(rule, row["input"]).to_s).to eq(row["expected"])
      end
    end
  end

  # Aggregate#storage_name is `Naming.snake(@name)` over an already-demodulised name.
  NAMING_VECTORS.fetch("storage_name").each do |row|
    it "storage name of #{row["input"].inspect} is #{row["expected"].inspect}" do
      expect(Hecks::Naming.snake(Hecks::Naming.demodulise(row["input"]))).to eq(row["expected"])
    end
  end

  NAMING_VECTORS.fetch("qualified_name").each do |row|
    it "qualified name of #{row["domain"].inspect} + #{row["suffix"][0, 12].inspect} is #{row["expected"].bytesize} bytes",
       :aggregate_failures do
      got = qualified_name(row["domain"], row["suffix"])

      expect(got).to eq(row["expected"])
      expect(got.bytesize).to be <= Hecks::Adapters::PostgresEra::Lineage::POSTGRES_IDENTIFIER_LIMIT
    end
  end
end
