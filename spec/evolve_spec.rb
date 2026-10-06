require "spec_helper"
require "tmpdir"
require "hecks/grammar/evolve"

# The file surgery under hecks propose, run against throwaway copies of the syntax tables.
# The tool's gates are proven by driving hecks propose itself, not here.
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

  # Proposes "annotate" on the Aggregate table and returns every keyword row and the new one.
  def propose_annotate(path, **options)
    EVOLVE.propose(word: "annotate", context: "Aggregate", path: path, **options)
    rows = EVOLVE.keyword_rows(path)
    [rows, rows.find { |candidate| candidate[:word] == "annotate" }]
  end

  def propose_annotate_as(path, status)
    propose_annotate(path)
    EVOLVE.set_status(word: "annotate", context: "Aggregate", to: status, path: path)
  end

  def annotate_row(path)
    EVOLVE.keyword_rows(path).find { |row| row[:word] == "annotate" }
  end

  def rename_emits(path)
    EVOLVE.rename(word: "emits", context: "Command", to: "announces", path: path)
  end

  def renamed_rows(path)
    rename_emits(path)
    EVOLVE.keyword_rows(path)
  end

  def renamed_argument_rows(paths)
    rename_emits(paths)
    EVOLVE.argument_rows(paths)
  end

  # The text before the `value_object "<seed>"` block in `source`, and the file's text now.
  def before_and_after(source, path, seed)
    before_block = source[0...source.index(/^\s*value_object "#{seed}" do$/)]
    [before_block, File.read(path)]
  end

  def annotate_retired_text(path, source)
    propose_annotate_as(path, "retired")
    before_and_after(source, path, "KeywordSeed")
  end

  def propose_locale(path, kind: "text")
    EVOLVE.propose_argument(keyword: "vision", context: "Bluebook", kind: kind, named: "locale", path: path)
  end

  def proposed_locale(path)
    propose_locale(path)
    rows = EVOLVE.argument_rows(path)
    [rows, rows.find { |candidate| candidate[:keyword] == "vision" && candidate[:named] == "locale" }]
  end

  def proposed_locale_row
    { keyword: "vision", context: "Bluebook", at: "", named: "locale",
      kind: "text", required: "false", fills: "", status: "proposed" }
  end

  def set_locale_status(path, to)
    EVOLVE.set_argument_status(keyword: "vision", context: "Bluebook", to: to, named: "locale", path: path)
  end

  def locale_row(path)
    EVOLVE.argument_rows(path).find { |r| r[:keyword] == "vision" && r[:named] == "locale" }
  end

  def locale_retired_text(path, source)
    propose_locale(path)
    set_locale_status(path, "retired")
    before_and_after(source, path, "ArgumentSeed")
  end

  def set_attribute_argument_status(path, to, named)
    EVOLVE.set_argument_status(keyword: "attribute", context: "Aggregate", to: to, named: named, path: path)
  end

  def pattern_row(path)
    EVOLVE.argument_rows(path)
          .find { |r| r[:keyword] == "attribute" && r[:context] == "Aggregate" && r[:named] == "pattern" }
  end

  # The write reaches disk before the raise, so restoration must undo it.
  def rename_then_raise(paths)
    EVOLVE.restore_on_raise(paths) do
      rename_emits(paths)
      raise "boom mid-cascade"
    end
  end

  it "reads every keyword row, absent status as admitted", :aggregate_failures do
    rows = EVOLVE.keyword_rows
    expect(rows.size).to be > 70
    # Asserts only that an absent status: reads back as "admitted" and no status is blank;
    # which words are deprecated is not pinned.
    expect(rows.map { |row| row[:status] }.uniq.sort).to eq(%w[admitted deprecated])
    expect(rows.map { |row| row[:status] }).to all(satisfy { |status| !status.to_s.empty? })
  end

  it "proposes a word as one row, proposed, at the table's foot", :aggregate_failures do
    with_copy("Aggregate") do |path|
      rows, row = propose_annotate(path, fills: "description")

      expect(row).to eq(word: "annotate", context: "Aggregate", status: "proposed", was: nil)
      expect(rows.last).to eq(row)
    end
  end

  it "refuses a second row for the same word and context" do
    with_copy("Aggregate") do |path|
      propose_annotate(path)

      expect { propose_annotate(path) }.to raise_error(EVOLVE::Refusal, /one row per/)
    end
  end

  it "admits by removing the ceremony — an admitted row spells no status", :aggregate_failures do
    with_copy("Aggregate") do |path|
      propose_annotate_as(path, "admitted")

      expect(File.read(path).lines.find { |l| l.include?('word: "annotate"') }).not_to include("status:")
      expect(annotate_row(path)[:status]).to eq("admitted")
    end
  end

  it "deprecates and retires by spelling the station" do
    with_copy("Command") do |path|
      EVOLVE.set_status(word: "given", context: "Command", to: "deprecated", path: path)
      row = EVOLVE.keyword_rows(path).find { |r| r[:word] == "given" && r[:context] == "Command" }
      expect(row[:status]).to eq("deprecated")
    end
  end

  it "renames by respelling the row and holding the old spelling in was", :aggregate_failures do
    with_copy("Command") do |path|
      rows = renamed_rows(path)

      expect(rows.find { |r| r[:word] == "announces" && r[:context] == "Command" }[:was]).to eq("emits")
      expect(rows.none? { |r| r[:word] == "emits" && r[:context] == "Command" }).to be(true)
    end
  end

  it "refuses a second rename hop" do
    with_copy("Command") do |path|
      rename_emits(path)

      expect { EVOLVE.rename(word: "announces", context: "Command", to: "declares", path: path) }
        .to raise_error(EVOLVE::Refusal, /one rename hop/)
    end
  end

  it "refuses a rename onto a living word" do
    with_copy("Command") do |path|
      expect { EVOLVE.rename(word: "given", context: "Command", to: "role", path: path) }
        .to raise_error(EVOLVE::Refusal, /living word/)
    end
  end

  it "refuses a station the language does not admit" do
    with_copy("Command") do |path|
      expect { EVOLVE.set_status(word: "given", context: "Command", to: "banished", path: path) }
        .to raise_error(EVOLVE::Refusal, /not a station/)
    end
  end

  it "refuses a word the language does not hold" do
    with_copy("Command") do |path|
      expect { EVOLVE.set_status(word: "imagined", context: "Command", to: "retired", path: path) }
        .to raise_error(EVOLVE::Refusal, /not declared/)
    end
  end

  it "touches nothing outside the Keyword one_of block", :aggregate_failures do
    with_copy("Aggregate") do |path, source|
      before_block, after = annotate_retired_text(path, source)

      expect(after[0...before_block.size]).to eq(before_block)
      expect(after).to include('value_object "ArgumentSeed"')
    end
  end

  # Argument rows: a keyword may carry several, so identity is (keyword, context, at, named).

  it "reads every argument row", :aggregate_failures do
    rows = EVOLVE.argument_rows
    expect(rows.size).to be > 100
    # The one-symbol refusal is an arity rule, not a row lifecycle; the symbol row stays admitted.
    expect(rows.map { |row| row[:status] }.uniq).to eq(["admitted"])
  end

  it "proposes an argument as one row, proposed, at the table's foot", :aggregate_failures do
    with_copy("Bluebook") do |path|
      rows, row = proposed_locale(path)

      expect(row).to eq(proposed_locale_row)
      expect(rows.last).to eq(row)
    end
  end

  it "refuses a second row for the same (keyword, context, at, named)" do
    with_copy("Bluebook") do |path|
      propose_locale(path)

      expect { propose_locale(path, kind: "symbol") }.to raise_error(EVOLVE::Refusal, /already declared/)
    end
  end

  it "admits an argument by removing the ceremony" do
    with_copy("Bluebook") do |path|
      propose_locale(path)
      set_locale_status(path, "admitted")

      expect(locale_row(path)[:status]).to eq("admitted")
    end
  end

  it "deprecates and retires an argument by spelling the station" do
    with_copy("Aggregate") do |path|
      set_attribute_argument_status(path, "deprecated", "pattern")

      expect(pattern_row(path)[:status]).to eq("deprecated")
    end
  end

  it "refuses an argument station the language does not admit" do
    with_copy("Aggregate") do |path|
      expect { set_attribute_argument_status(path, "banished", "pattern") }
        .to raise_error(EVOLVE::Refusal, /not a station/)
    end
  end

  it "refuses an argument the language does not hold" do
    with_copy("Aggregate") do |path|
      expect { set_attribute_argument_status(path, "retired", "imagined") }
        .to raise_error(EVOLVE::Refusal, /not declared/)
    end
  end

  it "cascades a keyword rename onto that keyword's own argument rows, and no other's", :aggregate_failures do
    with_copies("Command", "PortOperation") do |paths|
      rows = renamed_argument_rows(paths)

      # Scoped to the (keyword, context) pair: "emits" under "PortOperation" is a different word.
      expect(rows.none? { |r| r[:keyword] == "emits" && r[:context] == "Command" }).to be(true)
      expect(rows.any? { |r| r[:keyword] == "emits" && r[:context] == "PortOperation" }).to be(true)
    end
  end

  it "does not cascade a keyword rename onto other keywords by substring" do
    with_copies("Command", "PortOperation") do |paths|
      rows = renamed_argument_rows(paths)

      expect(rows.any? { |r| r[:keyword] == "attribute" }).to be(true)
    end
  end

  it "touches nothing outside the Argument one_of block" do
    with_copy("Bluebook") do |path, source|
      before_block, after = locale_retired_text(path, source)

      expect(after[0...before_block.size]).to eq(before_block)
    end
  end

  # The `--name value` flag reader: takes the next argv element only if it is not a flag.
  describe ".option" do
    it "reads a flag's value" do
      expect(EVOLVE.option(["--context", "Aggregate"], "context")).to eq("Aggregate")
    end

    it "does not swallow a following flag as the value", :aggregate_failures do
      expect(EVOLVE.option(["--foo", "--bar", "baz"], "foo")).to be_nil
      expect(EVOLVE.option(["--foo", "--bar", "baz"], "bar")).to eq("baz")
    end

    it "falls back to the given default when the flag is absent or value-less", :aggregate_failures do
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

    it "restores every snapshotted file, and re-raises, when the block raises after partial writes", :aggregate_failures do
      with_copies("Command", "PortOperation") do |paths|
        contents = paths.to_h { |path| [path, File.read(path)] }

        expect { rename_then_raise(paths) }.to raise_error("boom mid-cascade")

        paths.each { |path| expect(File.read(path)).to eq(contents[path]) }
      end
    end
  end
end
