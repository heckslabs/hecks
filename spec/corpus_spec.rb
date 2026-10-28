require "spec_helper"

# The corpus member list is derived, not listed, so a new member is covered without edits here.
# Per-member loading is proven by spec/model_check_spec.rb's "the real corpus" walk.
RSpec.describe "The corpus" do
  # Example domains load by folder; grammar bluebooks and framework members are flat files.
  EXAMPLE_ROOTS = Hecks::Corpus.members(:example).map(&:path).freeze
  GRAMMAR_CHAPTERS = Hecks::Corpus.members(:grammar).map(&:path).freeze
  FRAMEWORK_MEMBERS = Hecks::Corpus.members(:framework).map(&:path).freeze

  # [corpus-script stem, bluebook path]
  CORPUS_MEMBERS = Hecks::Corpus.members(:example, :grammar, :framework)
                                .map { |member| [member.stem, Hecks::Corpus.source_of(member)] }.freeze

  it "finds every domain the corpus declares", :aggregate_failures do
    expect(EXAMPLE_ROOTS).not_to be_empty
    expect(GRAMMAR_CHAPTERS).not_to be_empty
    expect(FRAMEWORK_MEMBERS).not_to be_empty
    expect(CORPUS_MEMBERS.map(&:last)).to all(be_truthy)
  end

  it "gives every corpus member a script" do
    CORPUS_MEMBERS.each do |stem, bluebook|
      script = File.join(InMemoryDomain::ROOT, "spec", "corpus", "#{stem}.json")
      expect(File).to exist(script), "no corpus script for #{bluebook} — expected #{script}"
    end
  end

  it "lists every .adapter file, leaving out vendored copies", :aggregate_failures do
    files = Hecks::Corpus.adapter_files
    expect(files).to include(File.join(Hecks::Corpus::ROOT, "lib/hecks/adapters/driven/heki.adapter"))
    expect(files.grep(%r{/(vendor|node_modules|target)/})).to be_empty
  end

  it "lists every .world file, leaving out vendored copies", :aggregate_failures do
    files = Hecks::Corpus.world_files
    expect(files).to include(File.join(Hecks::Corpus::ROOT, "lib/hecks/hecks/deploy.world"))
    expect(files).to eq(files.sort)
    expect(files.grep(%r{/(vendor|node_modules|target)/})).to be_empty
  end
end
