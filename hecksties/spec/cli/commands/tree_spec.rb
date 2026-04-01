require "spec_helper"
require "hecks_cli"

# Hecks CLI tree command spec
#
# Verifies that `hecks tree` prints all registered commands
# grouped by source module, and that `--format json` outputs
# valid JSON with the same structure.
RSpec.describe "hecks tree" do
  let(:cli) { Hecks::CLI.new }

  before { allow($stdout).to receive(:puts) }

  it "prints grouped command tree in text mode" do
    output = capture_tree_output
    expect(output).to include("Hecks CLI Commands")
    expect(output).to include("build")
    expect(output).to include("validate")
    expect(output).to include("inspect")
    expect(output).to include("visualize")
  end

  it "outputs valid JSON with --format json" do
    require "json"
    output = capture_tree_output(format: "json")
    parsed = JSON.parse(output)
    expect(parsed).to be_a(Hash)
    all_names = parsed.values.flatten.map { |c| c["name"] }
    expect(all_names).to include("build")
    expect(all_names).to include("validate")
  end

  def capture_tree_output(format: nil)
    opts = {}
    opts[:format] = format if format
    allow(cli).to receive(:options).and_return(opts)
    output = StringIO.new
    allow(cli.shell).to receive(:say) { |msg, *| output.puts(msg) }
    cli.tree
    output.string
  end
end
