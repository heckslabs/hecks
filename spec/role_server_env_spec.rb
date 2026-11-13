require "spec_helper"
require "tmpdir"
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

  it "names the patterns that match no command of the served domain, and only those" do
    found = described_class.new(patterns: ["Dispatch.fill!", "Work.start!", "git status", "Nope.*"], names: -> { NAMES })
    expect(found.unserved).to eq(["Nope.*"])
  end

  it "builds variables a commands server accepts", :aggregate_failures do
    scope = Hecks::Adapters::Driving::McpScope.from_env(variables("Dispatch.*"))
    expect(scope).to be_commands_mode
    expect(scope.allowed_commands).to eq(%w[dispatch.fill dispatch.settle])
  end

  describe "the Agents bluebook's rows" do
    let(:guard) { Hecks::Adapters::RoutingGuard.new }
    let(:scribe_rows) do
      [{ role: "scribe", pattern: "AgentRun.check_all!" }, { role: "scribe", pattern: "SendTrain.board!" }]
    end
    let(:scribe) { Hecks::Adapters::RoutingGuard.new(settings: { rows: ->(_table) { scribe_rows } }) }

    def lines(role) = guard.server_env(role: { value: role })[:text].lines.map(&:chomp)

    it "leaves the orchestrator and a role with no rows unrestricted", :aggregate_failures do
      expect(lines("orchestrator")).to eq([])
      expect(lines("coder")).to eq([])
    end

    it "plans a role with rows as restricted, and the orchestrator as one with none", :aggregate_failures do
      expect(scribe.server_plan("scribe")).to include(rows: true)
      expect(guard.server_plan("orchestrator")).to eq(rows: false, variables: {}, commands: [], unserved: [])
    end

    it "does not write a table made of stand-in rows" do
      with_cache_root do
        scribe.server_env(role: { value: "scribe" })
        expect(Hecks::RoleServerCache.lookup(File.expand_path("..", __dir__), "scribe")).to eq(:miss)
      end
    end

    def with_cache_root
      home = Dir.mktmpdir("role-env-cache")
      saved = ENV.fetch("XDG_CACHE_HOME", nil)
      ENV["XDG_CACHE_HOME"] = home
      Hecks::CacheDir.reset!
      yield
    ensure
      ENV["XDG_CACHE_HOME"] = saved
      Hecks::CacheDir.reset!
      FileUtils.remove_entry(home)
    end

    it "refuses a checkout that has no Agents bluebook, so a caller can fall back" do
      missing = Hecks::Adapters::RoutingGuard.new(checkout: Dir.mktmpdir("no-checkout"))
      expect { missing.server_plan("orchestrator") }.to raise_error(StandardError)
    end
  end
end
