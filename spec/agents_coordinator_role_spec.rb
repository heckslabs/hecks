require "spec_helper"
require_relative "../lib/hecks/agents/adapters/routing_guard"
require_relative "support/coordinator_role_data"

# The orchestrator is the pipeline's coordinator, declared as data in the Agents bluebook: its
# routing rows refuse what the owner alone may do, and its role file names the question markers.
RSpec.describe "the orchestrator as the coordinator role" do
  include CoordinatorRoleData

  it "refuses claude stop and names AgentRun.answer!" do
    expect { refusal("claude stop abc") }.to raise_error(Hecks::Adapters::RoutingGuard::Refused, /never stops or kills/)
  end

  it "refuses Landing.discard! as the owner's alone" do
    expect { refusal("exe/hecks Landing.discard! branch.value=x") }
      .to raise_error(Hecks::Adapters::RoutingGuard::Refused, /owner's alone/)
  end

  it "refuses HECKS_OWNER_PUSH as the owner's override" do
    expect { refusal("HECKS_OWNER_PUSH=x git push") }
      .to raise_error(Hecks::Adapters::RoutingGuard::Refused, /owner's one-off/)
  end

  it "lists the verbs the coordinator needs", :aggregate_failures do
    expect(patterns).to include("Integration.advance!", "Heartbeat.beat!", "Ticker.stop!", "Work.*", "LinkedTree.pull_main!")
  end

  it "does not rehearse deep or stop a session", :aggregate_failures do
    expect(role_file).not_to include("claude stop")
    expect(role_file).not_to include("scope.value=deep")
  end

  it "names the question markers and the review wait", :aggregate_failures do
    expect(role_file).to include("`[choose]`, `[confirm]`, `[retry]` or `[owner]`", "`[review]`")
  end
end
