require "spec_helper"
require_relative "../support/parser_differential"

# Differential fuzzing of the two bluebook parsers. Generated and mutated bluebooks go to
# `hecks-parse` and to the Ruby loader, and the answers must relate in one of the ways the design
# allows (see `ParserDifferential.acceptable?`). Seeded: a failure names the seed that reproduces
# it, and `HECKS_PARSE_FUZZ_SEED` / `HECKS_PARSE_FUZZ_ITERATIONS` move or widen the run.
RSpec.describe "Parser differential fuzzing (hecks-parse vs Ruby)", :io do
  before(:context) { ParserDifferential.build! }

  it "has fixtures to mutate" do
    expect(ParserDifferential::FIXTURES).not_to be_empty
  end

  it "prints the same ir.json as Ruby for generated bluebooks, bare and after benign edits" do
    problems = ParserDifferential::Sweeps.generated_problems

    expect(problems).to be_empty, problems.first(3).join("\n---\n")
  end

  describe "mutated bluebooks" do
    let(:sweep) { ParserDifferential::Sweeps.mutation_sweep }

    it "stay inside the allowed relations" do
      _tally, problems = sweep

      expect(problems).to be_empty, problems.first(5).join("\n---\n")
    end

    it "include inputs both parsers accept, so something is actually compared" do
      tally, _problems = sweep

      expect(tally[:both_ok_same]).to be > 0
    end
  end
end
