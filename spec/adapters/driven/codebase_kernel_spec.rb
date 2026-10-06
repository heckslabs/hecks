require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/hecks/adapters/codebase/source_tree"

RSpec.describe Hecks::Adapters::Codebase::KernelTables do
  let(:tree) { Hecks::Adapters::Codebase::Tree.new }
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }
  let(:other) { Hecks::Adapters::Codebase::Tree.new(root: @dir) }

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  def shapes = File.join(@dir, "rust/src/kernel/attribute_shapes/mod.rs")

  def kernel(operation, held = {}, on: tree)
    described_class.call(operation, held, on)
  end

  describe "project_kernel_capabilities" do
    it "finds the checkout already holds what the grammar projects" do
      expect(kernel("project_kernel_capabilities")).to start_with("nothing to change")
    end

    it "reports drift and writes nothing until confirmed, in another tree", :aggregate_failures do
      dry = kernel("project_kernel_capabilities", {}, on: other)

      expect(dry).to include("dry run, 2 files differ", "new rust/src/kernel/attribute_shapes/mod.rs",
                             "new rust/src/kernel/expression_operators/mod.rs")
      expect(File.exist?(shapes)).to be(false)
    end

    it "writes what the grammar projects when confirmed, in another tree", :aggregate_failures do
      written = kernel("project_kernel_capabilities", { confirm: { value: true } }, on: other)

      expect(written).to start_with("wrote 2 files:")
      expect(File.read(shapes)).to eq(File.read(tree.path("rust/src/kernel/attribute_shapes/mod.rs")))
    end
  end

  describe "measure_kernel_coverage" do
    it "lists each capability the grammar admits, and the verdict, when every file is there", :aggregate_failures do
      report = kernel("measure_kernel_coverage")

      expect(report).to include("OK    rust/src/kernel/attribute_shapes/")
      expect(report).to match(%r{^([0-9]+)/\1 kernel capability files present})
    end

    it "refuses with each file that is missing, and writes nothing", :aggregate_failures do
      expect { kernel("measure_kernel_coverage", {}, on: other) }
        .to raise_error(failure, %r{MISS  rust/src/kernel/attribute_shapes/.*\n.*capability file\(s\) missing}m)
      expect(Dir.children(@dir)).to be_empty
    end
  end
end
