require "spec_helper"
require "hecks/hecks/adapters/codebase/source_tree"

RSpec.describe Hecks::Adapters::Codebase::CorpusTasks do
  let(:tree) { Hecks::Adapters::Codebase::Tree.new }
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }

  after do
    described_class.mcp_server = nil
    described_class.web_server = nil
    described_class.coverage_runner = nil
  end

  # Stands in for `Hecks::RustBuild`, recording each tool it is asked to run.
  def runner_answering(out, status = 0)
    asked = []
    result = Struct.new(:out, :err, :status) { def ok? = status.zero? }.new(out, "", status)
    runner = Object.new
    runner.define_singleton_method(:capture) do |tool, argv, env: {}|
      asked << { tool: tool, argv: argv, env: env }
      result
    end
    described_class.coverage_runner = runner
    asked
  end

  describe "the corpus questions" do
    it "lists each domain with a Rust feature, its feature and its directory", :aggregate_failures do
      lines = described_class.report("rust_domains", {}, tree).lines.map(&:chomp)

      expect(lines).not_to be_empty
      expect(lines.map { |line| line.split("\t").size }.uniq).to eq([2])
    end

    it "lists the directories regeneration walks, relative to the checkout", :aggregate_failures do
      lines = described_class.report("regen_order", {}, tree).lines.map(&:chomp)

      expect(lines).not_to be_empty
      expect(lines).to all(satisfy { |line| !line.start_with?("/") })
    end

    context "when every generated module passes" do
      let(:modules) { Hecks::Corpus.generated_modules(root: tree.root) }

      before do
        @asked = runner_answering("ok\n")
        @report = described_class.report("corpus_rust_coverage", {}, tree)
      end

      it "runs the coverage tool once for each generated module in this process", :aggregate_failures do
        expect(@asked.map { |ask| ask[:tool] }.uniq).to eq(["rust_coverage"])
        expect(@asked.map { |ask| ask[:argv] }).to eq(modules.map { |name| [name] })
      end

      it "points the tool at the checkout's Rust directory" do
        expect(@asked.first[:env]).to eq("HECKS_RUST_DIR" => tree.path("rust"))
      end

      it "says how many passed" do
        expect(@report).to end_with("#{modules.size} generated modules checked")
      end
    end

    it "refuses with each module that failed" do
      runner_answering("no route\n", 1)

      expect { described_class.report("corpus_rust_coverage", {}, tree) }
        .to raise_error(failure, /FAILED.*failed:\nno route/m)
    end
  end

  describe "the IR questions" do
    it "answers which propagation touchpoints show a construct's field" do
      expect(described_class.report("ir_impact", { name: "Aggregate", field: "preconditions" }, tree)).not_to be_empty
    end

    it "refuses a construct that is not one" do
      expect { described_class.report("ir_constructs", { names: "NoSuchConstruct" }, tree) }
        .to raise_error(failure)
    end
  end

  describe "the doors" do
    it "serves the MCP door on stdio, with no arguments, and notes when it closed", :aggregate_failures do
      served = nil
      described_class.mcp_server = ->(**options) { served = options }

      expect(described_class.call("serve_query_ir_mcp", {}, tree)).to eq("query ir mcp door closed")
      expect(served).to eq(argv: [])
    end

    it "refuses when the MCP door will not start" do
      described_class.mcp_server = ->(**) { exit(2) }

      expect { described_class.call("serve_query_ir_mcp", {}, tree) }.to raise_error(failure, /status 2/)
    end

    context "when the forms app is served" do
      let(:ports) { [] }

      before { described_class.web_server = ->(app:, port:) { ports << port if app.respond_to?(:call) } }

      it "serves the banking forms app on the port named" do
        described_class.call("present", { port: { value: 8080 } }, tree)

        expect(ports).to eq([8080])
      end

      it "serves it on 4567 otherwise, and notes when it stopped", :aggregate_failures do
        report = described_class.call("present", {}, tree)

        expect(ports).to eq([4567])
        expect(report).to eq("presented on port 4567, now stopped")
      end
    end
  end
end
