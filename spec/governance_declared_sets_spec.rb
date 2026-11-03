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

  describe "a storehouse call's caller, judged by the Call.Admit givens" do
    def caller_request(role: nil, actor_id: nil)
      Hecks::Storehouse::Request.new(role: role, actor_id: actor_id)
    end

    it "reads the two givens Call.Admit declares" do
      givens = Hecks::Framework.command_of("Governance", "Call", "Admit").givens.map(&:description)
      expect(givens).to contain_exactly("an actor names the role it holds", "a role-gated command has a caller bound")
    end

    it "refuses an actor who names no role", :aggregate_failures do
      expect { Hecks::Storehouse.admit_caller!(caller_request(actor_id: "pat"), "no", "order.create") }
        .to raise_error(Hecks::Runtime::Unauthorized, /an actor names the role it holds/)
      expect { Hecks::Storehouse.admit_caller!(caller_request(role: "Chef", actor_id: "pat"), "no", "order.create") }
        .not_to raise_error
    end

    it "refuses a role-gated command with no caller bound, and admits one with a role", :aggregate_failures do
      expect { Hecks::Storehouse.admit_caller!(caller_request, "yes", "order.create") }
        .to raise_error(Hecks::Runtime::Unauthorized, /a role-gated command has a caller bound/)
      expect { Hecks::Storehouse.admit_caller!(caller_request(role: "Chef"), "yes", "order.create") }
        .not_to raise_error
    end
  end

  it "masks a database URL password under the name Privacy declares" do
    expect(Hecks::Secrets.database_secret_name).to eq("database password")
  end

  it "refuses a set the member does not declare" do
    expect { Hecks::Framework.closed_set("Governance", "Call", "Nope") }
      .to raise_error(Hecks::Runtime::WiringError, /declares no Call.Nope/)
  end
end
