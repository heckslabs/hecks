require "spec_helper"
require "json"
require "hecks/fuzzing"
require_relative "support/conformance_corpus"

# The Ruby half of the conformance corpus: Ruby answers each fixture as written, exactly as the
# compiled Rust kernel does in spec/rust_conformance_spec.rb. Expectations are data, seeded once
# by `hecks test_suite_run.seed_semantics_corpus` and reviewed; Ruby is a reference
# implementation, not the oracle.
RSpec.describe "the conformance corpus" do
  def replayed_expectation(fixture)
    Hecks::CLI::SeedSemanticsCorpus.expectation_for(InMemoryDomain::ROOT, fixture, full: true)
  end

  ConformanceCorpus.paths.each do |path|
    it "#{File.basename(path)} carries a frozen expect" do
      expect(ConformanceCorpus.load(path))
        .to have_key("expect"), "no expect — run hecks test_suite_run.seed_semantics_corpus and review the seed"
    end

    it "Ruby answers #{File.basename(path)} as written", :aggregate_failures do
      fixture = ConformanceCorpus.load(path)
      frozen = fixture.fetch("expect")
      replayed = replayed_expectation(fixture)

      expect(replayed.keys).to match_array(frozen.keys)
      frozen.each { |key, value| expect(replayed.fetch(key)).to eq(value), "#{key} differs" }
    end
  end
end
