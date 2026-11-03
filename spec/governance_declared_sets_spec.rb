require "spec_helper"

# The closed lists a storehouse call and a restricted MCP server are held to live in Governance's
# `Call` and `Door` aggregates; the code reads them and keeps no copy.
RSpec.describe "Governance declared sets" do
  def declared(aggregate, value_object)
    Hecks::Framework.closed_set("Governance", aggregate, value_object)
  end

  it "gives Storehouse its source and surface lists", :aggregate_failures do
    expect(Hecks::Storehouse::SOURCE_TAGS).to eq(declared("Call", "Source"))
    expect(Hecks::Storehouse::SURFACES).to eq(declared("Call", "Surface"))
    expect(Hecks::Storehouse::SURFACES).to include("cli", "mcp")
  end

  it "gives McpScope its tool lists", :aggregate_failures do
    scope = Hecks::Adapters::Driving::McpScope
    expect(scope::READER_TOOLS).to eq(declared("Door", "ReaderTool"))
    expect(scope::COMMAND_TOOLS).to eq(scope::READER_TOOLS + ["dispatch"])
  end

  it "gives McpScope its argument lists", :aggregate_failures do
    scope = Hecks::Adapters::Driving::McpScope
    expect(scope::DENIED_ARGUMENTS).to include("confirm", "host", "url", "write")
    expect(scope::PATH_ARGUMENTS).to eq(declared("Door", "PathArgument"))
    expect(scope::REF_ARGUMENTS).to eq(declared("Door", "RefArgument"))
  end

  it "refuses a set the member does not declare" do
    expect { Hecks::Framework.closed_set("Governance", "Call", "Nope") }
      .to raise_error(Hecks::Runtime::WiringError, /declares no Call.Nope/)
  end
end
