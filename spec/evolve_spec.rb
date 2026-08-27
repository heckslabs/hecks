require "spec_helper"
require "tmpdir"
require "hecks/grammar/evolve"

# The file surgery under bin/evolve, exercised against throwaway COPIES
# of the aggregate-local syntax tables — never the tree's own. The tool's gates
# (regenerate, run the conformance specs, restore on red) are proven by
# driving bin/evolve itself; what this file pins is the surgery: a
# proposal lands as a hand would write it, admission removes the
# ceremony (absent status reads as admitted), and the region outside
# Keyword's one_of block is never touched.
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
    # S17/ADR 0026's relationship-cardinality slice un-deprecated
    # has_many/has_one/belongs_to for real (they build and dispatch now,
    # not merely refuse outside shadow_parse) — but `then_set` (item #13's
    # own slice 5 rename of `sets`) is a real "deprecated" row again,
    # kept refusing live only so shadow_parse can still read frozen era
    # text that used the old spelling. The claim this test actually
    # holds — an ABSENT status: column reads back as "admitted", never
    # blank — needs no particular status SET to prove; it only needs
    # every present value to be non-empty, checked below.
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

  # ── the Argument rows — a word's own arguments, the same lifecycle one
  # level down. A keyword may carry several, so identity is the full
  # (keyword, context, at, named) tuple.

  it "reads every argument row" do
    rows = EVOLVE.argument_rows
    expect(rows.size).to be > 100
    # ADR 0029 restores the named value-object and `as:` rows. The symbol
    # row remains admitted because two-or-more symbols are the live compound
    # key form; its one-symbol refusal is an arity rule, not a row lifecycle.
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

      # SCOPED TO THE RENAMED (keyword, context) PAIR, not the bare word —
      # "emits" legitimately still exists under "PortOperation" (a hecksagon
      # port operation's own emits, a different keyword-in-context entirely),
      # untouched because the rename named "Command" specifically.
      expect(rows.none? { |r| r[:keyword] == "emits" && r[:context] == "Command" }).to be(true)
      expect(rows.any? { |r| r[:keyword] == "emits" && r[:context] == "PortOperation" }).to be(true)
      # `attribute`'s OWN rows (a different keyword) must survive untouched —
      # the cascade is scoped to the renamed keyword only, never a blind
      # substring match across the whole table.
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

  # bin/evolve's own `--name value` flag reader (`option`, wrapping this).
  # A bare value-arity contract: consume the next argv element ONLY when
  # it doesn't itself look like a flag.
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

  # The restore-on-raise ceremony `guarded` (bin/evolve) wraps every
  # mutating command's body in: a raise partway through a multi-file
  # cascade (rename's keyword-row write followed by its argument
  # cascade, in particular) must not leave any snapshotted file
  # half-changed.
  describe ".restore_on_raise" do
    it "leaves every file untouched on a clean return" do
      with_copies("Command") do |paths|
        contents = paths.to_h { |path| [path, File.read(path)] }
        EVOLVE.restore_on_raise(paths) { EVOLVE.rename(word: "emits", context: "Command", to: "announces", path: paths) }
        expect(paths.any? { |path| File.read(path) != contents[path] }).to be(true) # the rename really landed
      end
    end

    it "restores every snapshotted file, and re-raises, when the block raises after partial writes" do
      with_copies("Command", "PortOperation") do |paths|
        contents = paths.to_h { |path| [path, File.read(path)] }

        expect do
          EVOLVE.restore_on_raise(paths) do
            # Simulate a mid-cascade raise: the keyword row lands (one
            # real file write, same shape as `rename`'s own first step)
            # before the failure — proving restoration undoes a write
            # that already reached disk, not merely one still pending.
            EVOLVE.rename(word: "emits", context: "Command", to: "announces", path: paths)
            raise "boom mid-cascade"
          end
        end.to raise_error("boom mid-cascade")

        paths.each { |path| expect(File.read(path)).to eq(contents[path]) }
      end
    end
  end
end
