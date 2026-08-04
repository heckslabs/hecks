require "hecksagain"
require "json"

RSpec.describe Hecksagain::Naming do
  CONTRACT_PATH = File.expand_path("corpus/fixtures/naming.json", __dir__)
  CONTRACT = JSON.parse(File.read(CONTRACT_PATH)).freeze

  def self.cases(rule) = CONTRACT.fetch(rule)

  it "reads every rule in the contract" do
    expect(CONTRACT.keys).to contain_exactly(
      "snake", "demodulise", "reference_key",
      "split_dotted", "qualifier", "unqualified", "split_verb"
    )
  end

  describe ".snake" do
    cases("snake").each do |row|
      it "#{row['in'].inspect} becomes #{row['out'].inspect}" do
        expect(described_class.snake(row["in"])).to eq(row["out"])
      end
    end
  end

  describe ".demodulise" do
    cases("demodulise").each do |row|
      it "#{row['in'].inspect} becomes #{row['out'].inspect}" do
        expect(described_class.demodulise(row["in"])).to eq(row["out"])
      end
    end
  end

  describe ".reference_key" do
    cases("reference_key").each do |row|
      it "#{row['in'].inspect} becomes #{row['out'].inspect}" do
        expect(described_class.reference_key(row["in"]).to_s).to eq(row["out"])
      end
    end

    it "answers a Symbol, which is how Ruby addresses a key" do
      expect(described_class.reference_key("Transfer")).to be_a(Symbol)
    end
  end

  describe ".split_dotted" do
    cases("split_dotted").each do |row|
      it "#{row['in'].inspect} becomes #{row['out'].inspect}" do
        expect(described_class.split_dotted(row["in"])).to eq(row["out"])
      end
    end
  end

  describe ".qualifier" do
    cases("qualifier").each do |row|
      it "#{row['in'].inspect} becomes #{row['out'].inspect}" do
        expect(described_class.qualifier(row["in"])).to eq(row["out"])
      end
    end
  end

  describe ".unqualified" do
    cases("unqualified").each do |row|
      it "#{row['in'].inspect} becomes #{row['out'].inspect}" do
        expect(described_class.unqualified(row["in"])).to eq(row["out"])
      end
    end
  end

  describe ".split_verb" do
    cases("split_verb").each do |row|
      it "#{row['in'].inspect} becomes #{row['out'].inspect}" do
        expect(described_class.split_verb(row["in"])).to eq(row["out"])
      end
    end
  end

  # NOT in the shared contract above, the same way `.plural` beside it in the
  # source is not : both are used to derive one aggregate's name from
  # another's, which the SAME naming rule (`snake`, `reference_key`, …)
  # is checked against everywhere else, so a divergence here would already
  # surface downstream rather than silently. Kept as its own direct
  # spec because `has_many`/`has_one`/`belongs_to` must resolve
  # `has_many Invoices` to the Invoice aggregate, and this pins how.
  describe ".singularize" do
    it "turns ies into y" do
      expect(described_class.singularize("Invoices")).to eq("Invoice")
      expect(described_class.singularize("Stories")).to eq("Story")
    end

    it "drops a trailing s" do
      expect(described_class.singularize("Tasks")).to eq("Task")
      expect(described_class.singularize("Boards")).to eq("Board")
    end

    it "leaves a word with no recognised suffix alone" do
      expect(described_class.singularize("Sheep")).to eq("Sheep")
      expect(described_class.singularize("Children")).to eq("Children")
    end

    it "survives the degenerate inputs" do
      expect(described_class.singularize("")).to eq("")
      expect(described_class.singularize("s")).to eq("s")
    end
  end
end
