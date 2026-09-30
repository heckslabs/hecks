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
    it "lists each domain with a Rust feature, its feature and its directory" do
      lines = described_class.report("rust_domains", {}, tree).lines.map(&:chomp)

      expect(lines).not_to be_empty
      expect(lines.map { |line| line.split("\t").size }.uniq).to eq([2])
    end

    it "lists the directories regeneration walks, relative to the checkout" do
      lines = described_class.report("regen_order", {}, tree).lines.map(&:chomp)

      expect(lines).not_to be_empty
      expect(lines).to all(satisfy { |line| !line.start_with?("/") })
    end

    it "runs the coverage tool once for each generated module in this process, and says how many passed" do
      asked = runner_answering("ok\n")

      report = described_class.report("corpus_rust_coverage", {}, tree)

      modules = Hecks::Corpus.generated_modules(root: tree.root)
      expect(asked.map { |ask| ask[:tool] }.uniq).to eq(["rust_coverage"])
      expect(asked.map { |ask| ask[:argv] }).to eq(modules.map { |name| [name] })
      expect(asked.first[:env]).to eq("HECKS_RUST_DIR" => tree.path("rust"))
      expect(report).to end_with("#{modules.size} generated modules checked")
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
    it "serves the MCP door on stdio, with no arguments, and notes when it closed" do
      served = nil
      described_class.mcp_server = ->(**options) { served = options }

      report = described_class.call("serve_query_ir_mcp", {}, tree)

      expect(served).to eq(argv: [])
      expect(report).to eq("query ir mcp door closed")
    end

    it "refuses when the MCP door will not start" do
      described_class.mcp_server = ->(**) { exit(2) }

      expect { described_class.call("serve_query_ir_mcp", {}, tree) }.to raise_error(failure, /status 2/)
    end

    it "serves the banking forms app on the port named, and on 4567 otherwise" do
      ports = []
      described_class.web_server = lambda do |app:, port:|
        expect(app).to respond_to(:call)
        ports << port
      end

      described_class.call("present", { port: { value: 8080 } }, tree)
      report = described_class.call("present", {}, tree)

      expect(ports).to eq([8080, 4567])
      expect(report).to eq("presented on port 4567, now stopped")
    end
  end
end
