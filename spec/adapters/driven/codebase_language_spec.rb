require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/hecks/adapters/codebase/source_tree"

RSpec.describe Hecks::Adapters::Codebase::Language do
  let(:tree) { Hecks::Adapters::Codebase::Tree.new }
  let(:console_failure) { Hecks::Adapters::ConsoleCapture::Failure }

  # Answers a fixed status for every child process and remembers what it was asked.
  let(:shell_class) do
    Class.new do
      attr_reader :asked

      def initialize(*statuses)
        (@statuses = statuses
         @asked = [])
      end

      def capture(*command, env: {}, chdir: nil)
        @asked << { command: command, env: env, chdir: chdir }
        status = @statuses.shift || 0
        Hecks::Adapters::Shell::Result.new("ran", "", Struct.new(:success?, :exitstatus).new(status.zero?, status))
      end
    end
  end

  def language(operation, held, shell: shell_class.new)
    described_class.call(operation, held, tree, shell: shell)
  end

  describe "a projection" do
    it "finds the tree already holds what the language projects" do
      described_class::PROJECTIONS.each_key do |operation|
        expect(language(operation, {})).to start_with("nothing to change"), operation
      end
    end

    it "answers the projected text, and writes nothing, for stdout" do
      text = language("project_expression_tables", { stdout: { value: true }, confirm: { value: true } })

      expect(text).to eq(File.read(tree.path("lib/hecks/bluebook/expression/projection.json")))
    end

    context "with another tree" do
      around do |example|
        Dir.mktmpdir do |dir|
          @dir = dir
          example.run
        end
      end

      let(:other) { Hecks::Adapters::Codebase::Tree.new(root: @dir) }

      def target = File.join(@dir, "lib/hecks/vocabulary.rb")

      # A file the Rust vocabulary no longer emits.
      def plant_retired_table
        FileUtils.mkdir_p(File.join(@dir, "rust/src/kernel/vocab"))
        File.join(@dir, "rust/src/kernel/vocab/retired_table.rs").tap { |path| File.write(path, "// no longer projected\n") }
      end

      it "reports drift without writing, unless confirmed", :aggregate_failures do
        dry = described_class.call("project_vocabulary", {}, other)

        expect(dry).to include("dry run, 1 files differ", "new lib/hecks/vocabulary.rb")
        expect(File.exist?(target)).to be(false)
      end

      it "writes what the language projects when confirmed", :aggregate_failures do
        written = described_class.call("project_vocabulary", { confirm: { value: true } }, other)

        expect(written).to start_with("wrote 1 files:")
        expect(File.read(target)).to eq(File.read(tree.path("lib/hecks/vocabulary.rb")))
      end

      it "keeps what the Rust vocabulary no longer emits, unless confirmed" do
        stale = plant_retired_table

        described_class.call("project_rust_vocabulary", {}, other)

        expect(File.exist?(stale)).to be(true)
      end

      it "removes what the Rust vocabulary no longer emits when confirmed", :aggregate_failures do
        stale = plant_retired_table

        report = described_class.call("project_rust_vocabulary", { confirm: { value: true } }, other)

        expect(report).to include("removed rust/src/kernel/vocab/retired_table.rs")
        expect(File.exist?(stale)).to be(false)
      end
    end
  end

  describe "the words' standing" do
    it "counts the keyword rows and names each one that is moving", :aggregate_failures do
      status = described_class.word_status

      expect(status).to match(/\A[0-9]+ keyword rows; [0-9]+ not simply admitted; [0-9]+ renamed/)
      expect(status).to include("Command.then_set")
    end
  end

  describe "an evolution" do
    let(:tree) { @copy }
    let(:shell) { shell_class.new }

    def tables = Hecks::Grammar::Evolve.syntax_paths
    def golden = tree.path(described_class::GOLDEN)

    def snapshot = (tables + [golden]).to_h { |path| [path, File.read(path)] }

    # The edits are real, so they land on a copy of the language's bluebooks and golden. Run on
    # the checkout's own files they were visible, half-made, to every other process loading the
    # grammar while this one ran, which showed up as a syntax error or a missing aggregate there.
    around do |example|
      Dir.mktmpdir do |dir|
        language = File.join(dir, "lib/hecks/language")
        FileUtils.mkdir_p(File.dirname(language))
        FileUtils.cp_r(Hecks::Grammar::Evolve.language_dir, language)
        FileUtils.mkdir_p(File.join(dir, File.dirname(described_class::GOLDEN)))
        FileUtils.cp(Hecks::Adapters::Codebase::Tree.new.path(described_class::GOLDEN),
                     File.join(dir, described_class::GOLDEN))
        @copy = Hecks::Adapters::Codebase::Tree.new(root: dir)
        Hecks::Grammar::Evolve.with_language_dir(language) { example.run }
      end
    end

    it "rehearses the edit without writing when it is not confirmed", :aggregate_failures do
      before = snapshot

      report = language("propose", { word: { value: "no_such_word" }, context: { value: "Aggregate" } })

      expect(report).to start_with("dry run, 1 file changes")
      expect(report).to include("lib/hecks/language/bluebook/aggregate.bluebook (+1 -0 lines)")
      expect(snapshot).to eq(before)
    end

    it "refuses a word that is not declared, in words, and changes nothing", :aggregate_failures do
      before = snapshot

      expect { language("admit", { word: { value: "no_such_word" }, context: { value: "Aggregate" } }) }
        .to raise_error(console_failure, /Aggregate\.no_such_word is not declared/)
      expect(snapshot).to eq(before)
    end

    it "refuses to propose a word twice" do
      expect { language("propose", { word: { value: "attribute" }, context: { value: "Aggregate" } }) }
        .to raise_error(console_failure, /already declared/)
    end

    it "refuses a rename that goes nowhere" do
      expect { language("rename", { word: { value: "attribute" }, context: { value: "Aggregate" } }) }
        .to raise_error(console_failure, /a rename goes somewhere/)
    end

    # Proposes a word that is not declared yet, confirmed, answering the report.
    def propose_confirmed(shell)
      language("propose", { word: { value: "no_such_word" }, context: { value: "Aggregate" },
                            confirm: { value: true } }, shell: shell)
    end

    context "when confirmed and the gates hold" do
      let(:report) { propose_confirmed(shell) }

      before { report }

      it "makes the edit" do
        expect(File.read(tables.find { |path| path.end_with?("aggregate.bluebook") }))
          .to include('word: "no_such_word", context: "Aggregate"')
      end

      it "says the gates hold, and what to teach the builder" do
        expect(report).to include("Aggregate.no_such_word — the gates hold", "teach the Aggregate builder the word")
      end

      it "regenerates the golden first", :aggregate_failures do
        expect(shell.asked.map { |ask| ask[:command].last(3) }.first).to eq(%w[exec rspec spec/ir_golden_spec.rb])
        expect(shell.asked.first[:env]).to eq("GOLDEN" => "rewrite")
      end

      it "runs the gates last, from the tree's root", :aggregate_failures do
        expect(shell.asked.last[:command]).to include(*described_class::GATES)
        expect(shell.asked.map { |ask| ask[:chdir] }.uniq).to eq([tree.root])
      end
    end

    it "puts every file back when a gate refuses, and says what failed", :aggregate_failures do
      before = snapshot

      expect { propose_confirmed(shell_class.new(0, 1)) }.to raise_error(console_failure, /RESTORED — the gates refused/)
      expect(snapshot).to eq(before)
    end
  end
end
