require "spec_helper"

# The agent scope is opt-in: a command is an agent tool only when it explicitly declares `:agent`.
RSpec.describe Hecks::Storehouse, ".agent_commands" do
  let(:runtime) { boot_in_memory }

  it "treats a command with no declared audience as not an agent tool" do
    expect(described_class.agent_commands(runtime)).to be_empty
  end

  it "lists exactly the commands that declare the agent audience" do
    cli = { commands: { "create_pizza" => { audience: %w[person agent] }, "purchase" => { audience: [] } } }
    allow(described_class).to receive(:cli_for).and_return(cli)
    expect(described_class.agent_commands(runtime)).to eq(["create_pizza"])
  end
end
