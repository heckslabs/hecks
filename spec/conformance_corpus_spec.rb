require "spec_helper"
require "json"
require "hecks/fuzzing"
require_relative "support/conformance_corpus"

# The Ruby half of the conformance corpus: Ruby answers each fixture as written, exactly as the
# compiled Rust kernel does in spec/rust_conformance_spec.rb. Expectations are data, seeded once
# by `hecks seed_semantics_corpus` and reviewed; Ruby is a reference implementation, not the oracle.
RSpec.describe "the conformance corpus" do
  ConformanceCorpus.paths.each do |path|
    it "Ruby answers #{File.basename(path)} as written" do
      fixture = ConformanceCorpus.load(path)
      expect(fixture).to have_key("expect"), "no expect — run hecks seed_semantics_corpus and review the seed"
      frozen = fixture.fetch("expect")
      replayed = Hecks::CLI::SeedSemanticsCorpus.expectation_for(InMemoryDomain::ROOT, fixture, full: true)

      expect(replayed.keys).to match_array(frozen.keys)
      frozen.each { |key, value| expect(replayed.fetch(key)).to eq(value), "#{key} differs" }
    end
  end
end
