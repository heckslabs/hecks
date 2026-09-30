require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/tools"
require_relative "../../support/fake_codebase_shell"
require "hecks/hecks/adapters/codebase/source_tree"

RSpec.describe Hecks::Adapters::Codebase::Conformance do
  let(:tree) { Hecks::Adapters::Codebase::Tree.new }
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }

  # Answers the matrix's report with a fixed status, and remembers what the tool was asked. The
  # matrix runs in this process, so what is stubbed is `Hecks::Tools.run`.
  def fake_matrix(status = 0)
    FakeCodebaseShell.new(["kept 3 rows", status]).tap do |shell|
      allow(Hecks::Tools).to receive(:run, &shell.method(:run_tool))
    end
  end

  # A scratch checkout holding only the files the engine check reads.
  def scratch_checkout(dir)
    (Hecks::EngineAgreement::ENGINE_FILES.values + [Hecks::EngineAgreement::SHARED_COMPARISON_FILE] +
      Hecks::EngineAgreement::AGREEMENT_SPEC_FILES).each do |relative|
      FileUtils.mkdir_p(File.dirname(File.join(dir, relative)))
      FileUtils.cp(tree.path(relative), File.join(dir, relative))
    end
    Hecks::Adapters::Codebase::Tree.new(root: dir)
  end

  describe "check_engine_agreement" do
    it "finds the engines agreeing, in this checkout" do
      expect(described_class.call("check_engine_agreement", {}, tree))
        .to match(/declared comparator\(s\).*0 problems\./)
    end

    it "refuses with the engine that grew its own case" do
      Dir.mktmpdir do |dir|
        other = scratch_checkout(dir)
        engine = File.join(dir, Hecks::EngineAgreement::ENGINE_FILES.values.first)
        File.write(engine, "#{File.read(engine)}\nCase = ->(x) { case x when \"eq\" then 1 end }\n")

        expect { described_class.call("check_engine_agreement", {}, other) }
          .to raise_error(failure, /1 problem\(s\) found.*has its own `when "eq"`/m)
      end
    end

    it "refuses a comparator no agreement spec exercises" do
      Dir.mktmpdir do |dir|
        other = scratch_checkout(dir)
        Hecks::EngineAgreement::AGREEMENT_SPEC_FILES.each { |relative| File.write(File.join(dir, relative), "") }

        expect { described_class.call("check_engine_agreement", {}, other) }
          .to raise_error(failure, /no example in .* exercises/m)
      end
    end
  end

  describe "measure_doc_coverage" do
    it "finds every live word carrying prose and a running example, in this checkout" do
      expect(described_class.call("measure_doc_coverage", {}, tree))
        .to eq("every live word carries prose and a running example.")
    end

    it "refuses with the words that owe each, in a tree with no reference pages" do
      Dir.mktmpdir do |dir|
        other = Hecks::Adapters::Codebase::Tree.new(root: dir)

        expect { described_class.call("measure_doc_coverage", {}, other) }
          .to raise_error(failure, /live words carry no prose — write their sections:.*no running example/m)
      end
    end
  end

  describe "argument_gate_matrix" do
    it "only reports, running the tool without --write, unless confirmed" do
      shell = fake_matrix

      report = described_class.call("argument_gate_matrix", {}, tree)

      expect(report).to eq("kept 3 rows")
      expect(shell.asked.first[:command]).to eq(["argument_gate_matrix"])
      expect(shell.asked.first[:chdir]).to eq(tree.root)
    end

    it "rewrites the matrix and fixtures with --write when confirmed" do
      shell = fake_matrix

      described_class.call("argument_gate_matrix", { confirm: { value: true } }, tree)

      expect(shell.asked.first[:command]).to eq(["argument_gate_matrix", "--write"])
    end

    it "refuses with what the tool printed when it ends badly" do
      fake_matrix(1)

      expect { described_class.call("argument_gate_matrix", {}, tree) }
        .to raise_error(failure, "kept 3 rows")
    end
  end
end
