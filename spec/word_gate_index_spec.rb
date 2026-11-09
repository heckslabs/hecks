require "spec_helper"

# The word gate's index is memoized per grammar table. Readers on several threads, one of them
# swapping the table, must each get the index of the table they asked about, never nil.
RSpec.describe Hecks::Bluebook::DSL::WordGate, ".index_for" do
  def table(tag) = [{ context: "Ctx#{tag}", word: "word#{tag}", was: "" }].freeze

  def indexes_seen(tables)
    reads = -> { Array.new(200) { tables.map { |keywords| [keywords, described_class.index_for(keywords)] } }.flatten(1) }
    Array.new(4) { Thread.new(&reads) }.flat_map(&:value)
  end

  it "answers each table its own index across threads", :aggregate_failures do
    tables = [table("A"), table("B"), table("C")]

    indexes_seen(tables).each do |keywords, index|
      expect(index).not_to be_nil
      expect(index.keys).to include([keywords.first[:context], keywords.first[:word]])
    end
  end

  it "answers the words of the table it was asked about" do
    expect(described_class.words_of(table("D"))).to eq("wordD" => true, "" => true)
  end
end
