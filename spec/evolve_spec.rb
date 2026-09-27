require "spec_helper"
require "tmpdir"
require "hecks/grammar/evolve"

# The file surgery under bin/evolve, run against throwaway copies of the syntax tables.
# The tool's gates are proven by driving bin/evolve itself, not here.
RSpec.describe "the evolve surgery" do
  EVOLVE = Hecks::Grammar::Evolve

  def syntax_source_for(context)
    EVOLVE.syntax_paths.find { |path| File.read(path).include?(%(context: "#{context}")) } or
      raise "no syntax source owns #{context}"
  end

  def with_copy(context)
    Dir.mktmpdir("evolve") do |dir|
      source_path = syntax_source_for(context)
      path = File.join(dir, File.basename(source_path))
      source = File.read(source_path)
      File.write(path, source)
      yield path, source
    end
  end

  def with_copies(*contexts)
    Dir.mktmpdir("evolve") do |dir|
      paths = contexts.map do |context|
        source_path = syntax_source_for(context)
        path = File.join(dir, File.basename(source_path))
        File.write(path, File.read(source_path))
        path
      end.uniq
      yield paths
    end
  end

  it "reads every keyword row, absent status as admitted" do
    rows = EVOLVE.keyword_rows
    expect(rows.size).to be > 70
    # Asserts only that an absent status: reads back as "admitted" and no status is blank;
    # which words are deprecated is not pinned.
    expect(rows.map { |row| row[:status] }.uniq.sort).to eq(%w[admitted deprecated])
    expect(rows.map { |row| row[:status] }).to all(satisfy { |status| !status.to_s.empty? })
  end

  it "proposes a word as one row, proposed, at the table's foot" do
    with_copy("Aggregate") do |path|
      Hecks::Grammar::Evolve.propose(word: "annotate", context: "Aggregate",
                                     fills: "description", path: path)
      rows = Hecks::Grammar::Evolve.keyword_rows(path)
      row = rows.find { |candidate| candidate[:word] == "annotate" }

      expect(row).to eq(word: "annotate", context: "Aggregate", status: "proposed", was: nil)
      expect(rows.last).to eq(row)
    end
  end

  it "refuses a second row for the same word and context" do
    with_copy("Aggregate") do |path|
      Hecks::Grammar::Evolve.propose(word: "annotate", context: "Aggregate", path: path)

      expect do
        Hecks::Grammar::Evolve.propose(word: "annotate", context: "Aggregate", path: path)
      end.to raise_error(Hecks::Grammar::Evolve::Refusal, /one row per/)
    end
  end

  it "admits by removing the ceremony — an admitted row spells no status" do
    with_copy("Aggregate") do |path|
      Hecks::Grammar::Evolve.propose(word: "annotate", context: "Aggregate", path: path)
      Hecks::Grammar::Evolve.set_status(word: "annotate", context: "Aggregate",
                                        to: "admitted", path: path)

      line = File.read(path).lines.find { |l| l.include?('word: "annotate"') }
      expect(line).not_to include("status:")
      expect(Hecks::Grammar::Evolve.keyword_rows(path)
               .find { |row| row[:word] == "annotate" }[:status]).to eq("admitted")
    end
  end

  it "deprecates and retires by spelling the station" do
    with_copy("Command") do |path|
      Hecks::Grammar::Evolve.set_status(word: "given", context: "Command",
                                        to: "deprecated", path: path)
      row = Hecks::Grammar::Evolve.keyword_rows(path)
                                  .find { |r| r[:word] == "given" && r[:context] == "Command" }
      expect(row[:status]).to eq("deprecated")
    end
  end

  it "renames by respelling the row and holding the old spelling in was" do
    with_copy("Command") do |path|
      Hecks::Grammar::Evolve.rename(word: "emits", context: "Command", to: "announces", path: path)
      rows = Hecks::Grammar::Evolve.keyword_rows(path)

      expect(rows.find { |r| r[:word] == "announces" && r[:context] == "Command" }[:was]).to eq("emits")
      expect(rows.none? { |r| r[:word] == "emits" && r[:context] == "Command" }).to be(true)
    end
  end

  it "refuses a second rename hop, and a rename onto a living word" do
    with_copy("Command") do |path|
      Hecks::Grammar::Evolve.rename(word: "emits", context: "Command", to: "announces", path: path)

      expect do
        Hecks::Grammar::Evolve.rename(word: "announces", context: "Command", to: "declares", path: path)
      end.to raise_error(Hecks::Grammar::Evolve::Refusal, /one rename hop/)

      expect do
        Hecks::Grammar::Evolve.rename(word: "given", context: "Command", to: "role", path: path)
      end.to raise_error(Hecks::Grammar::Evolve::Refusal, /living word/)
    end
  end

  it "refuses a station the language does not admit, and a word it does not hold" do
    with_copy("Command") do |path|
      expect do
        Hecks::Grammar::Evolve.set_status(word: "given", context: "Command",
                                          to: "banished", path: path)
      end.to raise_error(Hecks::Grammar::Evolve::Refusal, /not a station/)

      expect do
        Hecks::Grammar::Evolve.set_status(word: "imagined", context: "Command",
                                          to: "retired", path: path)
      end.to raise_error(Hecks::Grammar::Evolve::Refusal, /not declared/)
    end
  end

  it "touches nothing outside the Keyword one_of block" do
    with_copy("Aggregate") do |path, source|
      Hecks::Grammar::Evolve.propose(word: "annotate", context: "Aggregate", path: path)
      Hecks::Grammar::Evolve.set_status(word: "annotate", context: "Aggregate",
                                        to: "retired", path: path)

      before_block = source[0...source.index(/^\s*value_object "KeywordSeed" do$/)]
      after = File.read(path)
      expect(after[0...before_block.size]).to eq(before_block)
      expect(after).to include('value_object "ArgumentSeed"')
    end
  end

  # Argument rows: a keyword may carry several, so identity is (keyword, context, at, named).

  it "reads every argument row" do
    rows = EVOLVE.argument_rows
    expect(rows.size).to be > 100
    # The one-symbol refusal is an arity rule, not a row lifecycle; the symbol row stays admitted.
    expect(rows.map { |row| row[:status] }.uniq).to eq(["admitted"])
  end

  it "proposes an argument as one row, proposed, at the table's foot" do
    with_copy("Bluebook") do |path|
      Hecks::Grammar::Evolve.propose_argument(keyword: "vision", context: "Bluebook", kind: "text",
                                              named: "locale", path: path)
      rows = Hecks::Grammar::Evolve.argument_rows(path)
      row  = rows.find { |candidate| candidate[:keyword] == "vision" && candidate[:named] == "locale" }

      expect(row).to eq(keyword: "vision", context: "Bluebook", at: "", named: "locale",
                        kind: "text", required: "false", fills: "", status: "proposed")
      expect(rows.last).to eq(row)
    end
  end

  it "refuses a second row for the same (keyword, context, at, named)" do
    with_copy("Bluebook") do |path|
      Hecks::Grammar::Evolve.propose_argument(keyword: "vision", context: "Bluebook", kind: "text",
                                              named: "locale", path: path)

      expect do
        Hecks::Grammar::Evolve.propose_argument(keyword: "vision", context: "Bluebook", kind: "symbol",
                                                named: "locale", path: path)
      end.to raise_error(Hecks::Grammar::Evolve::Refusal, /already declared/)
    end
  end

  it "admits an argument by removing the ceremony" do
    with_copy("Bluebook") do |path|
      Hecks::Grammar::Evolve.propose_argument(keyword: "vision", context: "Bluebook", kind: "text",
                                              named: "locale", path: path)
      Hecks::Grammar::Evolve.set_argument_status(keyword: "vision", context: "Bluebook", to: "admitted",
                                                 named: "locale", path: path)

      row = Hecks::Grammar::Evolve.argument_rows(path)
                                  .find { |r| r[:keyword] == "vision" && r[:named] == "locale" }
      expect(row[:status]).to eq("admitted")
    end
  end

  it "deprecates and retires an argument by spelling the station" do
    with_copy("Aggregate") do |path|
      Hecks::Grammar::Evolve.set_argument_status(keyword: "attribute", context: "Aggregate",
                                                 to: "deprecated", named: "pattern", path: path)
      row = Hecks::Grammar::Evolve.argument_rows(path)
                                  .find { |r| r[:keyword] == "attribute" && r[:context] == "Aggregate" && r[:named] == "pattern" }
      expect(row[:status]).to eq("deprecated")
    end
  end

  it "refuses a station or an argument the language does not hold" do
    with_copy("Aggregate") do |path|
      expect do
        Hecks::Grammar::Evolve.set_argument_status(keyword: "attribute", context: "Aggregate",
                                                   to: "banished", named: "pattern", path: path)
      end.to raise_error(Hecks::Grammar::Evolve::Refusal, /not a station/)

      expect do
        Hecks::Grammar::Evolve.set_argument_status(keyword: "attribute", context: "Aggregate",
                                                   to: "retired", named: "imagined", path: path)
      end.to raise_error(Hecks::Grammar::Evolve::Refusal, /not declared/)
    end
  end

  it "cascades a keyword rename onto that keyword's own argument rows, and no other's" do
    with_copies("Command", "PortOperation") do |paths|
      Hecks::Grammar::Evolve.rename(word: "emits", context: "Command", to: "announces", path: paths)
      rows = Hecks::Grammar::Evolve.argument_rows(paths)

      # Scoped to the (keyword, context) pair: "emits" under "PortOperation" is a different word.
      expect(rows.none? { |r| r[:keyword] == "emits" && r[:context] == "Command" }).to be(true)
      expect(rows.any? { |r| r[:keyword] == "emits" && r[:context] == "PortOperation" }).to be(true)
      # The cascade must not match other keywords by substring.
      expect(rows.any? { |r| r[:keyword] == "attribute" }).to be(true)
    end
  end

  it "touches nothing outside the Argument one_of block" do
    with_copy("Bluebook") do |path, source|
      Hecks::Grammar::Evolve.propose_argument(keyword: "vision", context: "Bluebook", kind: "text",
                                              named: "locale", path: path)
      Hecks::Grammar::Evolve.set_argument_status(keyword: "vision", context: "Bluebook", to: "retired",
                                                 named: "locale", path: path)

      before_block = source[0...source.index(/^\s*value_object "ArgumentSeed" do$/)]
      after = File.read(path)
      expect(after[0...before_block.size]).to eq(before_block)
    end
  end

  # The `--name value` flag reader: takes the next argv element only if it is not a flag.
  describe ".option" do
    it "reads a flag's value" do
      expect(EVOLVE.option(["--context", "Aggregate"], "context")).to eq("Aggregate")
    end

    it "does not swallow a following flag as the value" do
      expect(EVOLVE.option(["--foo", "--bar", "baz"], "foo")).to be_nil
      expect(EVOLVE.option(["--foo", "--bar", "baz"], "bar")).to eq("baz")
    end

    it "falls back to the given default when the flag is absent or value-less" do
      expect(EVOLVE.option(["--other", "x"], "foo", "fallback")).to eq("fallback")
      expect(EVOLVE.option(["--foo"], "foo", "fallback")).to eq("fallback")
    end
  end

  # A raise partway through a multi-file cascade must not leave any snapshotted file half-changed.
  describe ".restore_on_raise" do
    it "leaves every file untouched on a clean return" do
      with_copies("Command") do |paths|
        contents = paths.to_h { |path| [path, File.read(path)] }
        EVOLVE.restore_on_raise(paths) { EVOLVE.rename(word: "emits", context: "Command", to: "announces", path: paths) }
        # the rename really landed
        expect(paths.any? { |path| File.read(path) != contents[path] }).to be(true)
      end
    end

    it "restores every snapshotted file, and re-raises, when the block raises after partial writes" do
      with_copies("Command", "PortOperation") do |paths|
        contents = paths.to_h { |path| [path, File.read(path)] }

        expect do
          EVOLVE.restore_on_raise(paths) do
            # The write reaches disk before the raise, so restoration must undo it.
            EVOLVE.rename(word: "emits", context: "Command", to: "announces", path: paths)
            raise "boom mid-cascade"
          end
        end.to raise_error("boom mid-cascade")

        paths.each { |path| expect(File.read(path)).to eq(contents[path]) }
      end
    end
  end
end
