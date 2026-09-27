require "hecks/cli"
require "open3"
require "rbconfig"
require "stringio"

# The `hecks` router (ADR 0066): what it answers without running anything, and
# that a routed subcommand prints what its `bin/` script prints.
RSpec.describe Hecks::CLI do
  let(:root) { File.expand_path("..", __dir__) }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }

  def start(*argv) = described_class.start(argv, out: out, err: err)

  it "lists every subcommand on --help and exits 0" do
    expect(start("--help")).to eq(0)
    described_class::COMMANDS.each_key { |name| expect(out.string).to include("  #{name} ") }
  end

  it "lists the subcommands on stderr and exits 2 when given none" do
    expect(start).to eq(described_class::USAGE_STATUS)
    expect(err.string).to include("usage: hecks <command>")
    expect(out.string).to be_empty
  end

  it "refuses an unknown subcommand by name" do
    expect(start("frobnicate")).to eq(described_class::USAGE_STATUS)
    expect(err.string).to include('unknown command "frobnicate"')
  end

  it "prints one subcommand's usage for a lone --help without running it" do
    expect(start("mcp", "--help")).to eq(0)
    expect(out.string).to start_with("usage: hecks mcp [--stdio]")
  end

  it "routes to the same entry point bin/ runs", :io do
    hecks, = Open3.capture3(RbConfig.ruby, "exe/hecks", "ir", "examples/banking", chdir: root)
    bin, = Open3.capture3(RbConfig.ruby, "bin/ir", "examples/banking", chdir: root)

    expect(hecks).to start_with("{")
    expect(hecks).to eq(bin)
  end
end
