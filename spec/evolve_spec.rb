
require "spec_helper"
require "tmpdir"
require "hecksagain/grammar/evolve"

# The file surgery under bin/evolve, exercised against throwaway COPIES
# of the real syntax table — never the tree's own. The tool's gates
# (regenerate, run the conformance specs, restore on red) are proven by
# driving bin/evolve itself; what this file pins is the surgery: a
# proposal lands as a hand would write it, admission removes the
# ceremony (absent status reads as admitted), and the region outside
# Keyword's one_of block is never touched.
RSpec.describe "the evolve surgery" do
  EVOLVE_SOURCE = File.read(Hecksagain::Grammar::Evolve.syntax_path)

  def with_copy
    Dir.mktmpdir("evolve") do |dir|
      path = File.join(dir, "syntax.bluebook")
      File.write(path, EVOLVE_SOURCE)
      yield path
    end
  end

  it "reads every keyword row, absent status as admitted" do
    with_copy do |path|
      rows = Hecksagain::Grammar::Evolve.keyword_rows(path)
      expect(rows.size).to be > 70
      expect(rows.map { |row| row[:status] }.uniq).to eq(["admitted"])
    end
  end

  it "proposes a word as one row, proposed, at the table's foot" do
    with_copy do |path|
      Hecksagain::Grammar::Evolve.propose(word: "annotate", context: "Aggregate",
                                          fills: "description", path: path)
      rows = Hecksagain::Grammar::Evolve.keyword_rows(path)
      row = rows.find { |candidate| candidate[:word] == "annotate" }

      expect(row).to eq(word: "annotate", context: "Aggregate", status: "proposed", was: nil)
      expect(rows.last).to eq(row)
    end
  end

  it "refuses a second row for the same word and context" do
    with_copy do |path|
      Hecksagain::Grammar::Evolve.propose(word: "annotate", context: "Aggregate", path: path)

      expect do
        Hecksagain::Grammar::Evolve.propose(word: "annotate", context: "Aggregate", path: path)
      end.to raise_error(Hecksagain::Grammar::Evolve::Refusal, /one row per/)
    end
  end

  it "admits by removing the ceremony — an admitted row spells no status" do
    with_copy do |path|
      Hecksagain::Grammar::Evolve.propose(word: "annotate", context: "Aggregate", path: path)
      Hecksagain::Grammar::Evolve.set_status(word: "annotate", context: "Aggregate",
                                             to: "admitted", path: path)

      line = File.read(path).lines.find { |l| l.include?('word: "annotate"') }
      expect(line).not_to include("status:")
      expect(Hecksagain::Grammar::Evolve.keyword_rows(path)
               .find { |row| row[:word] == "annotate" }[:status]).to eq("admitted")
    end
  end

  it "deprecates and retires by spelling the station" do
    with_copy do |path|
      Hecksagain::Grammar::Evolve.set_status(word: "given", context: "Command",
                                             to: "deprecated", path: path)
      row = Hecksagain::Grammar::Evolve.keyword_rows(path)
                                       .find { |r| r[:word] == "given" && r[:context] == "Command" }
      expect(row[:status]).to eq("deprecated")
    end
  end

  it "renames by respelling the row and holding the old spelling in was" do
    with_copy do |path|
      Hecksagain::Grammar::Evolve.rename(word: "emits", context: "Command", to: "announces", path: path)
      rows = Hecksagain::Grammar::Evolve.keyword_rows(path)

      expect(rows.find { |r| r[:word] == "announces" && r[:context] == "Command" }[:was]).to eq("emits")
      expect(rows.none? { |r| r[:word] == "emits" && r[:context] == "Command" }).to be(true)
    end
  end

  it "refuses a second rename hop, and a rename onto a living word" do
    with_copy do |path|
      Hecksagain::Grammar::Evolve.rename(word: "emits", context: "Command", to: "announces", path: path)

      expect do
        Hecksagain::Grammar::Evolve.rename(word: "announces", context: "Command", to: "declares", path: path)
      end.to raise_error(Hecksagain::Grammar::Evolve::Refusal, /one rename hop/)

      expect do
        Hecksagain::Grammar::Evolve.rename(word: "given", context: "Command", to: "role", path: path)
      end.to raise_error(Hecksagain::Grammar::Evolve::Refusal, /living word/)
    end
  end

  it "refuses a station the language does not admit, and a word it does not hold" do
    with_copy do |path|
      expect do
        Hecksagain::Grammar::Evolve.set_status(word: "given", context: "Command",
                                               to: "banished", path: path)
      end.to raise_error(Hecksagain::Grammar::Evolve::Refusal, /not a station/)

      expect do
        Hecksagain::Grammar::Evolve.set_status(word: "imagined", context: "Command",
                                               to: "retired", path: path)
      end.to raise_error(Hecksagain::Grammar::Evolve::Refusal, /not declared/)
    end
  end

  it "touches nothing outside the Keyword one_of block" do
    with_copy do |path|
      Hecksagain::Grammar::Evolve.propose(word: "annotate", context: "Aggregate", path: path)
      Hecksagain::Grammar::Evolve.set_status(word: "annotate", context: "Aggregate",
                                             to: "retired", path: path)

      before_block = EVOLVE_SOURCE[0...EVOLVE_SOURCE.index(/^\s*value_object "Keyword" do$/)]
      after = File.read(path)
      expect(after[0...before_block.size]).to eq(before_block)
      expect(after).to include('value_object "Argument"')
    end
  end
end
