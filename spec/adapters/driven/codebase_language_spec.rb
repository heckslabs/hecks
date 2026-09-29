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

      def initialize(*statuses) = (@statuses = statuses; @asked = [])

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

    it "reports drift without writing, and writes only when confirmed, in another tree" do
      Dir.mktmpdir do |dir|
        other = Hecks::Adapters::Codebase::Tree.new(root: dir)
        target = File.join(dir, "lib/hecks/vocabulary.rb")

        dry = described_class.call("project_vocabulary", {}, other)
        expect(dry).to include("dry run, 1 files differ", "new lib/hecks/vocabulary.rb")
        expect(File.exist?(target)).to be(false)

        written = described_class.call("project_vocabulary", { confirm: { value: true } }, other)
        expect(written).to start_with("wrote 1 files:")
        expect(File.read(target)).to eq(File.read(tree.path("lib/hecks/vocabulary.rb")))
      end
    end

    it "removes what the Rust vocabulary no longer emits, only when confirmed" do
      Dir.mktmpdir do |dir|
        other = Hecks::Adapters::Codebase::Tree.new(root: dir)
        FileUtils.mkdir_p(File.join(dir, "rust/src/kernel/vocab"))
        stale = File.join(dir, "rust/src/kernel/vocab/retired_table.rs")
        File.write(stale, "// no longer projected\n")

        described_class.call("project_rust_vocabulary", {}, other)
        expect(File.exist?(stale)).to be(true)

        report = described_class.call("project_rust_vocabulary", { confirm: { value: true } }, other)
        expect(report).to include("removed rust/src/kernel/vocab/retired_table.rs")
        expect(File.exist?(stale)).to be(false)
      end
    end
  end

  describe "the words' standing" do
    it "counts the keyword rows and names each one that is moving" do
      status = described_class.word_status

      expect(status).to match(/\A[0-9]+ keyword rows; [0-9]+ not simply admitted; [0-9]+ renamed/)
      expect(status).to include("Command.then_set")
    end
  end

  describe "an evolution" do
    let(:tables) { Hecks::Grammar::Evolve.syntax_paths }
    let(:golden) { tree.path(described_class::GOLDEN) }

    def snapshot = (tables + [golden]).to_h { |path| [path, File.read(path)] }

    around do |example|
      before = snapshot
      example.run
    ensure
      before.each { |path, text| File.write(path, text) }
    end

    it "rehearses the edit without writing when it is not confirmed" do
      before = snapshot

      report = language("propose", { word: { value: "no_such_word" }, context: { value: "Aggregate" } })

      expect(report).to start_with("dry run, 1 file changes")
      expect(report).to include("lib/hecks/language/bluebook/aggregate.bluebook (+1 -0 lines)")
      expect(snapshot).to eq(before)
    end

    it "refuses a word that is not declared, in words, and changes nothing" do
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

    it "makes the edit, regenerates the golden and holds the gates when confirmed" do
      shell = shell_class.new
      report = language("propose", { word: { value: "no_such_word" }, context: { value: "Aggregate" },
                                     confirm: { value: true } }, shell: shell)

      expect(File.read(tables.find { |path| path.end_with?("aggregate.bluebook") }))
        .to include('word: "no_such_word", context: "Aggregate"')
      expect(report).to include("Aggregate.no_such_word — the gates hold", "teach the Aggregate builder the word")
      expect(shell.asked.map { |ask| ask[:command].last(3) }.first).to eq(%w[exec rspec spec/ir_golden_spec.rb])
      expect(shell.asked.first[:env]).to eq("GOLDEN" => "rewrite")
      expect(shell.asked.last[:command]).to include(*described_class::GATES)
      expect(shell.asked.map { |ask| ask[:chdir] }.uniq).to eq([tree.root])
    end

    it "puts every file back when a gate refuses, and says what failed" do
      before = snapshot
      shell = shell_class.new(0, 1)

      expect do
        language("propose", { word: { value: "no_such_word" }, context: { value: "Aggregate" },
                              confirm: { value: true } }, shell: shell)
      end.to raise_error(console_failure, /RESTORED — the gates refused/)
      expect(snapshot).to eq(before)
    end
  end
end
