require "spec_helper"
require "hecks/hecks/adapters/codebase/source_tree"
require_relative "../../support/fake_codebase_shell"

RSpec.describe Hecks::Adapters::Codebase::CorpusTasks do
  let(:tree) { Hecks::Adapters::Codebase::Tree.new }
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }

  after do
    described_class.mcp_server = nil
    described_class.web_server = nil
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

    it "runs the coverage check once for each generated module, and says how many passed" do
      shell = FakeCodebaseShell.new("ok\n")

      report = described_class.report("corpus_rust_coverage", {}, tree, shell: shell)

      modules = Hecks::Corpus.generated_modules(root: tree.root)
      expect(shell.asked.size).to eq(modules.size)
      expect(shell.command.first).to eq("exec")
      expect(report).to end_with("#{modules.size} generated modules checked")
    end

    it "refuses with each module that failed" do
      shell = FakeCodebaseShell.new(["no route\n", 1])

      expect { described_class.report("corpus_rust_coverage", {}, tree, shell: shell) }
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
