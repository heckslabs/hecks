require "spec_helper"
require "tmpdir"
require_relative "support/mcp_run_helper"

# `run`: a commands server runs a listed command by the name the launcher takes, through the
# launcher's own resolution and refusals. Each example starts a server over a scratch copy of the
# pizzas domain on Memory (HECKS_STOREHOUSE_ROOT), with one command added that declares `confirm`.
RSpec.describe "the MCP run tool" do
  include McpRunHelper

  let(:sandbox) { Dir.mktmpdir("mcp-run-tool") }
  let(:commands_env) do
    { "HECKS_STOREHOUSE_ROOT" => sandbox, "HECKS_SERVER_TOOLS" => "commands", "HECKS_SERVER_DOMAINS" => "pizzas",
      "HECKS_SERVER_COMMANDS" => "Order.create_pizza!,Order.discard_menu!,RoleAssignment.assign!" }
  end

  before { scratch_pizzas(sandbox) }
  after { FileUtils.rm_rf(sandbox) }

  context "when the server runs in commands mode" do
    let(:replies) do
      answers(commands_env, [list_request, run_call(2, "order.create_pizza!", "role" => "Chef", "args" => pizza_args),
                             run_call(3, "Order.create_pizza!", "args" => pizza_args), run_call(4, "Order.purchase!"),
                             run_call(5, "order.create_pizza"), run_call(6, "Order.discard_menu!", "role" => "Chef")])
    end

    it "serves run and names the commands it runs" do
      run_tool = replies[1]["tools"].find { |tool| tool["name"] == "run" }
      expect(run_tool["description"]).to include("Order.create_pizza!", "attached bluebook")
    end

    it "runs a listed command by another launcher spelling than the list's", :aggregate_failures do
      expect(payload(replies[2])).to include("ok" => true, "status" => 0)
      expect(payload(replies[2]).dig("answer", "state", "name")).to eq("Margherita")
    end

    it "refuses a role-gated command when no role is given, as dispatch does" do
      expect(payload(replies[3])["error"]).to include("refused — role: Chef, and the caller stated no role")
    end

    it "refuses a command off the list, one the launcher refuses, and one that declares confirm", :aggregate_failures do
      expect(payload(replies[4])["error"]).to include("is refused", "runs only HECKS_SERVER_COMMANDS")
      expect(payload(replies[5])["error"]).to include("names no command the launcher runs", "write it as order.create_pizza!")
      expect(payload(replies[6])["error"]).to include("declares confirm, so it runs only on the command line")
    end
  end

  context "when a call reaches an attached bluebook, a word that is no command, or writes a flag" do
    let(:replies) do
      answers(commands_env, [run_call(1, "RoleAssignment.assign!"),
                             run_call(2, "Order.create_pizza!", "role" => "Chef", "args" => { "--confirm" => true }),
                             run_call(3, "help")])
    end

    it "resolves an attached bluebook's command unprefixed, then holds it to its role" do
      expect(payload(replies[1])["error"]).to include("role: Governance administrator, and the caller stated no role")
    end

    it "refuses an argument name that would read as a flag" do
      expect(payload(replies[2])["error"]).to include("argument: \"--confirm\" is refused")
    end

    it "refuses a word that answers usage rather than running a command" do
      expect(payload(replies[3])["error"]).to include("names no command the launcher runs")
    end
  end

  context "when the server is not in commands mode" do
    let(:replies) do
      answers({ "HECKS_STOREHOUSE_ROOT" => sandbox },
              [list_request, run_call(2, "Order.create_pizza!", "domain" => "pizzas")])
    end

    it "does not serve run and refuses a call of it by name", :aggregate_failures do
      expect(tool_names(replies[1])).not_to include("run")
      expect(payload(replies[2])["error"]).to include("only a server in commands mode serves it")
    end
  end
end
