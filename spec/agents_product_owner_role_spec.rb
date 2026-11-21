require "spec_helper"
require "hecks/agents/adapters/routing_guard"
require_relative "support/role_file_slices"

# The product owner files and ranks work: it may open epics, plan, prioritize, categorize and
# assign work items and rerank epics; the guard refuses dispatching, landing, boarding and writes.
RSpec.describe "the product owner role" do
  include RoleFileSlices

  let(:guard) { Hecks::Adapters::RoutingGuard.new }

  def verdict(command)
    guard.guard(role: { value: "product-owner" }, command: { value: command })
  end

  def refusal(command)
    verdict(command)
    nil
  rescue Hecks::Adapters::RoutingGuard::Refused => e
    e.message
  end

  it "has its role file" do
    expect(File).to exist(File.join(RoleFileSlices::AGENTS, "product-owner.md"))
  end

  it "may open an epic and plan work", :aggregate_failures do
    expect(refusal("exe/hecks tickets Epic.open! epic.value=e1")).to be_nil
    expect(refusal("exe/hecks tickets Work.plan! work.value=w1")).to be_nil
  end

  it "may prioritize, categorize and assign work", :aggregate_failures do
    %w[Work.prioritize! Work.categorize! Work.assign!].each do |verb|
      expect(refusal("exe/hecks tickets #{verb} work.value=w1")).to be_nil
    end
  end

  it "may rerank an epic and read the board", :aggregate_failures do
    expect(refusal("exe/hecks tickets Epic.rerank! epic.value=e1")).to be_nil
    expect(refusal("exe/hecks tickets Work.undone")).to be_nil
  end

  it "refuses dispatching and landing", :aggregate_failures do
    expect(refusal("exe/hecks Dispatch.fill! run.value=x --confirm")).to include("Dispatch.fill!")
    expect(refusal("exe/hecks AgentRun.dispatch! agent.value=coder")).to include("AgentRun.dispatch!")
    expect(refusal("exe/hecks Landing.land! branch.value=b")).to include("Landing.land!")
  end

  it "refuses boarding and file writes", :aggregate_failures do
    expect(refusal("exe/hecks SendTrain.board! --confirm")).to include("SendTrain.board!")
    expect(refusal("echo x > lib/a.rb")).not_to be_nil
  end
end
