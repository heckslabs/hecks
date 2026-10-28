require "spec_helper"
require "hecks/rust_format"

# Fails when rust/parser/src/phrases.rs drifts from the Sentence bluebook's PhraseSeed rows:
# regenerates the file in memory and compares it with the committed one.
RSpec.describe "the generated sentence table" do
  let(:committed_path) { File.expand_path("../rust/parser/src/phrases.rs", __dir__) }
  let(:chapter) { Hecks::Projections::PhraseTable.chapter }

  def regenerated_table
    Hecks::RustFormat.call(Hecks::Projector.call(:phrase_table, bluebook: chapter))
  end

  it "is exactly what the phrase rows project right now", :aggregate_failures do
    expect(File).to exist(committed_path), "rust/parser/src/phrases.rs is missing — project the phrase_table"
    expect(File.read(committed_path))
      .to eq(regenerated_table), "rust/parser/src/phrases.rs is stale — project the phrase_table and commit the result"
  end

  describe "the rows" do
    let(:rows) { Hecks::Projections::PhraseTable.rows(chapter) }
    let(:contexts) do
      %w[File Domain Aggregate Has ValueObject Lifecycle Command Query Condition Policy ExamplesFile Examples Background
         Example Table Step Outcome Vision Fields Provides Report Process Handler]
    end

    it "declare each phrase once" do
      expect(rows.map { |row| row[:id] }).to eq(rows.map { |row| row[:id] }.uniq)
    end

    it "are legal in a context the parser knows" do
      expect(rows.map { |row| row[:context] }.uniq - contexts).to be_empty
    end

    it "open only a block the parser knows" do
      expect(rows.map { |row| row[:opens] }.uniq - ["", *contexts]).to be_empty
    end
  end

  it "gives every slot a kind the matcher reads", :aggregate_failures do
    kinds = %w[words word text int list rest path event]
    slots = Hecks::Projections::PhraseTable.rows(chapter)
                                           .flat_map { |row| row[:pattern].scan(/\{(\w+):(\w+)\}/) }

    expect(slots).not_to be_empty
    expect(slots.map(&:last).uniq - kinds).to be_empty
  end
end
