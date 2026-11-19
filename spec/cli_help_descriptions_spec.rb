require "spec_helper"
require_relative "support/cli_help_descriptions"

# What each line of the launcher's help says comes from the bluebooks, so no golden pins it: a
# branch that rewords a command changes its bluebook and the help follows, and the masked help
# snapshot (`spec/cli_help_snapshot_spec.rb`) stays as it is.
RSpec.describe "exe/hecks help descriptions", :io do
  it "says for each command the goal its bluebook declares" do
    expect(CliHelpDescriptions.undeclared_commands).to eq([])
  end

  it "shows each command and query row as its description, cut as its section cuts it", :aggregate_failures do
    expect(CliHelpDescriptions.listed_rows.size).to be > 200
    expect(CliHelpDescriptions.misquoted_rows).to eq([])
  end

  it "shows each bluebook row as the start of that bluebook's vision" do
    expect(CliHelpDescriptions.misquoted_bluebooks).to eq([])
  end

  it "notes each aggregate with the first sentence of its bluebook description" do
    expect(CliHelpDescriptions.misquoted_notes).to eq([])
  end
end
