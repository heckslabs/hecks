require "hecksagain"
require "json"

RSpec.describe Hecksagain::Naming do
  CONTRACT_PATH = File.expand_path("parity/fixtures/naming.json", __dir__)
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
end
