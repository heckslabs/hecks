require "spec_helper"
require "hecks/agents/adapters/routing_guard"

# A role's MCP server starts restricted to the commands its routing rows name, so it stays
# booted and serves the role's verbs. Names are injected; the last examples read the real
# Hecks domain.
RSpec.describe Hecks::Adapters::RoleServerEnv do
  NAMES = %w[dispatch.fill dispatch.settle agent_run.check_all agent_run.retire work.start].freeze

  def variables(*patterns) = described_class.new(patterns: patterns, names: -> { NAMES }).variables

  it "names an exact command, whichever way the pattern spells its end", :aggregate_failures do
    expect(variables("Dispatch.fill!")["HECKS_SERVER_COMMANDS"]).to eq("dispatch.fill")
    expect(variables("AgentRun.retire!")["HECKS_SERVER_COMMANDS"]).to eq("agent_run.retire")
  end

  it "expands a wildcard to every command of the aggregate, sorted" do
    expect(variables("Dispatch.*")["HECKS_SERVER_COMMANDS"]).to eq("dispatch.fill,dispatch.settle")
  end

  it "starts a commands server on the Hecks domain", :aggregate_failures do
    found = variables("Dispatch.fill!")
    expect(found["HECKS_SERVER_TOOLS"]).to eq("commands")
    expect(found["HECKS_SERVER_DOMAINS"]).to eq("lib/hecks/hecks")
  end

  it "adds nothing for a question, a shell command or a name the domain lacks" do
    expect(variables("Dispatch.preview", "git status", "Nope.verb!", "gh pr view")).to eq({})
  end

  it "joins the commands of several patterns once each" do
    expect(variables("Dispatch.fill!", "Dispatch.*")["HECKS_SERVER_COMMANDS"]).to eq("dispatch.fill,dispatch.settle")
  end

  it "builds variables a commands server accepts", :aggregate_failures do
    scope = Hecks::Adapters::Driving::McpScope.from_env(variables("Dispatch.*"))
    expect(scope).to be_commands_mode
    expect(scope.allowed_commands).to eq(%w[dispatch.fill dispatch.settle])
  end

  describe "the Agents bluebook's rows" do
    let(:guard) { Hecks::Adapters::RoutingGuard.new }

    def lines(role) = guard.server_env(role: { value: role })[:text].lines.map(&:chomp)

    it "restricts the orchestrator to the commands of its rows the Hecks domain has", :aggregate_failures do
      expect(lines("orchestrator")).to include("HECKS_SERVER_TOOLS=commands", "HECKS_SERVER_DOMAINS=lib/hecks/hecks")
      expect(lines("orchestrator").last).to include("dispatch.fill", "agent_run.check_all", "send_train.board")
    end

    it "leaves a role with no rows unrestricted" do
      expect(lines("coder")).to eq([])
    end
  end
end
