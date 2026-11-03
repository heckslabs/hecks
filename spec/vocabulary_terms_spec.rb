require "spec_helper"

# Each `Term` row of the Vocabulary names a thing of the tooling's own language and the storage
# word that must not stand in for it. The tooling bluebooks, the adapters behind their ports, the
# specs and the standing guides say the term; the phrase `<aggregate> <never>` anywhere in them
# fails here by file and line, so the word stays right after the rename that set it.
RSpec.describe "the terms of the tooling's language" do
  SPOKEN = %w[
    lib/hecks/hecks/**/* lib/hecks/tickets/**/* lib/hecks/coder/**/* lib/hecks/pipeline_board/**/*
    lib/hecks/quality_control/**/* lib/hecks/language/**/* spec/**/*.rb spec/golden/cli/*.txt
    CLAUDE.md .claude/skills/**/*.md .github/workflows/*.yml qa/bluebook/* qa/glossary/**/* qa/settings.yml
  ].freeze

  def root = InMemoryDomain::ROOT

  def terms = Hecks::Vocabulary::TABLES.fetch("Term")

  def spoken = Dir.glob(SPOKEN, base: root).select { |path| File.file?(File.join(root, path)) }

  def phrase(term) = /\b#{term["aggregate"]} #{term["never"]}s?\b/i

  def lines(path) = File.readlines(File.join(root, path), chomp: true).map(&:scrub)

  def said(term)
    spoken.flat_map do |path|
      lines(path).each_with_index.filter_map { |line, index| "#{path}:#{index + 1}" if line.match?(phrase(term)) }
    end
  end

  it "declares the work item" do
    expect(terms.map { |term| term["term"] }).to include("work item")
  end

  Hecks::Vocabulary::TABLES.fetch("Term").each do |term|
    it "says #{term["term"]}, never #{term["aggregate"]} #{term["never"]}, wherever the tooling speaks" do
      expect(said(term)).to be_empty
    end
  end
end
