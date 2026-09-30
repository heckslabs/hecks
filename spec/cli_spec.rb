require "hecks/cli"
require "open3"
require "rbconfig"
require "stringio"

# The `hecks` router (ADR 0066): what it answers without running anything, and
# that a routed subcommand prints what its library entry point prints.
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

  it "gives model_check the checkout it runs from, so it can sweep the corpus" do
    expect(described_class.checkout_root).to eq(root)
  end

  it "reads --wait as a flag to model_check, not as a domain name" do
    require "hecks/cli/model_check"
    check = -> { described_class::ModelCheck.call(["--wait", File.join(root, "examples/pizzas")], program: "hecks") }

    expect { check.call }.to output(/── pizzas/).to_stdout.and raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
  end

  it "routes to the library entry point `hecks ir` runs", :io do
    entry = '$LOAD_PATH.unshift("lib"); require "hecks/cli/ir"; Hecks::CLI::Ir.call(ARGV, program: "hecks ir")'
    hecks, = Open3.capture3(RbConfig.ruby, "exe/hecks", "ir", "examples/banking", chdir: root)
    library, = Open3.capture3(RbConfig.ruby, "-e", entry, "--", "examples/banking", chdir: root)

    expect(hecks).to start_with("{")
    expect(hecks).to eq(library)
  end
end
