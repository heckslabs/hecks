require_relative "../spec_helper"

RSpec.describe "Exemption lifecycle" do
  before { @app = Hecks.load(domain, force: true) }

  it "starts in 'requested' state" do
    agg = Exemption.request(
          model_id: "example",
          policy_id: "ref-id-123",
          requirement: "example",
          reason: "example"
        )
    expect(agg.status).to eq("requested")
  end

  it "RequestExemption transitions to 'requested'" do
    agg = Exemption.request(
          model_id: "example",
          policy_id: "ref-id-123",
          requirement: "example",
          reason: "example"
        )
    Exemption.request(model_id: "example", policy_id: "ref-id-123", requirement: "example", reason: "example")
    updated = Exemption.find(agg.id)
    expect(updated.status).to eq("requested")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("RequestedExemption")
  end

  it "ApproveExemption transitions to 'active'" do
    agg = Exemption.request(
          model_id: "example",
          policy_id: "ref-id-123",
          requirement: "example",
          reason: "example"
        )
    Exemption.request(model_id: "example", policy_id: "ref-id-123", requirement: "example", reason: "example")
    Exemption.approve(exemption_id: agg.id, approved_by_id: "example", expires_at: Date.today)
    updated = Exemption.find(agg.id)
    expect(updated.status).to eq("active")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("ApprovedExemption")
  end

  it "RevokeExemption transitions to 'revoked'" do
    agg = Exemption.request(
          model_id: "example",
          policy_id: "ref-id-123",
          requirement: "example",
          reason: "example"
        )
    Exemption.request(model_id: "example", policy_id: "ref-id-123", requirement: "example", reason: "example")
    Exemption.approve(exemption_id: agg.id, approved_by_id: "example", expires_at: Date.today)
    Exemption.revoke(exemption_id: agg.id)
    updated = Exemption.find(agg.id)
    expect(updated.status).to eq("revoked")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("RevokedExemption")
  end

  it "generates status predicates" do
    agg = Exemption.request(
          model_id: "example",
          policy_id: "ref-id-123",
          requirement: "example",
          reason: "example"
        )
    expect(agg.requested?).to be true
    expect(agg.active?).to be false
    expect(agg.revoked?).to be false
  end
end
