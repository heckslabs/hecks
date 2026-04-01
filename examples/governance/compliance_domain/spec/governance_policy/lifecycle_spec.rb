require_relative "../spec_helper"

RSpec.describe "GovernancePolicy lifecycle" do
  before { @app = Hecks.load(domain, force: true) }

  it "starts in 'draft' state" do
    agg = GovernancePolicy.create(
          name: "example",
          description: "example",
          category: "example",
          framework_id: "ref-id-123"
        )
    expect(agg.status).to eq("draft")
  end

  it "CreatePolicy transitions to 'draft'" do
    agg = GovernancePolicy.create(
          name: "example",
          description: "example",
          category: "example",
          framework_id: "ref-id-123"
        )
    GovernancePolicy.create(name: "example", description: "example", category: "example", framework_id: "ref-id-123")
    updated = GovernancePolicy.find(agg.id)
    expect(updated.status).to eq("draft")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("CreatedPolicy")
  end

  it "ActivatePolicy transitions to 'active'" do
    agg = GovernancePolicy.create(
          name: "example",
          description: "example",
          category: "example",
          framework_id: "ref-id-123"
        )
    GovernancePolicy.create(name: "example", description: "example", category: "example", framework_id: "ref-id-123")
    GovernancePolicy.activate(policy_id: agg.id, effective_date: Date.today)
    updated = GovernancePolicy.find(agg.id)
    expect(updated.status).to eq("active")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("ActivatedPolicy")
  end

  it "SuspendPolicy transitions to 'suspended'" do
    agg = GovernancePolicy.create(
          name: "example",
          description: "example",
          category: "example",
          framework_id: "ref-id-123"
        )
    GovernancePolicy.create(name: "example", description: "example", category: "example", framework_id: "ref-id-123")
    GovernancePolicy.activate(policy_id: agg.id, effective_date: Date.today)
    GovernancePolicy.suspend(policy_id: agg.id)
    updated = GovernancePolicy.find(agg.id)
    expect(updated.status).to eq("suspended")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("SuspendedPolicy")
  end

  it "RetirePolicy transitions to 'retired'" do
    agg = GovernancePolicy.create(
          name: "example",
          description: "example",
          category: "example",
          framework_id: "ref-id-123"
        )
    GovernancePolicy.create(name: "example", description: "example", category: "example", framework_id: "ref-id-123")
    GovernancePolicy.activate(policy_id: agg.id, effective_date: Date.today)
    GovernancePolicy.suspend(policy_id: agg.id)
    GovernancePolicy.retire(policy_id: agg.id)
    updated = GovernancePolicy.find(agg.id)
    expect(updated.status).to eq("retired")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("RetiredPolicy")
  end

  it "generates status predicates" do
    agg = GovernancePolicy.create(
          name: "example",
          description: "example",
          category: "example",
          framework_id: "ref-id-123"
        )
    expect(agg.draft?).to be true
    expect(agg.active?).to be false
    expect(agg.suspended?).to be false
  end
end
