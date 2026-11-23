require "spec_helper"
require "hecks/agents/adapters/routing_guard"

# Every role reads every query and every --help; only commands stay routed per role.
RSpec.describe "the routing guard on queries" do
  let(:guard) { Hecks::Adapters::RoutingGuard.new }
  let(:reads) { ["Work.priority_report", "Epic.ranked", "Work.show", "Fleet.stop! --help"] }

  def verdict(role, command) = guard.guard(role: { value: role }, command: { value: "exe/hecks #{command}" })

  def refusal(role, command)
    verdict(role, command)
  rescue Hecks::Adapters::RoutingGuard::Refused => e
    e.message
  end

  %w[planner product-owner architect orchestrator].each do |role|
    it "lets the #{role} read any query and any --help" do
      expect(reads.map { |call| verdict(role, call) }).to all(eq(text: "allowed"))
    end

    it "still refuses the #{role} a command it does not route" do
      expect(refusal(role, "Fleet.stop! x.value=1")).to include("#{role} routes only")
    end
  end

  it "refuses a query chained to another command" do
    expect(refusal("architect", "Work.show; rm x")).to include("architect routes only")
  end

  it "does not read a quoted --help as a request for help" do
    expect(refusal("architect", 'Fleet.stop! body="a --help b"')).to include("routes only")
  end

  it "names the role's own verbs in a refusal" do
    expect(refusal("product-owner", "Fleet.stop! x=1")).to include("Epic.open!")
  end
end
