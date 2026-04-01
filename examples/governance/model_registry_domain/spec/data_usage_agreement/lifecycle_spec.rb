require_relative "../spec_helper"

RSpec.describe "DataUsageAgreement lifecycle" do
  before { @app = Hecks.load(domain, force: true) }

  it "starts in 'draft' state" do
    agg = DataUsageAgreement.create(
          model_id: "ref-id-123",
          data_source: "example",
          purpose: "example",
          consent_type: "example"
        )
    expect(agg.status).to eq("draft")
  end

  it "CreateAgreement transitions to 'draft'" do
    agg = DataUsageAgreement.create(
          model_id: "ref-id-123",
          data_source: "example",
          purpose: "example",
          consent_type: "example"
        )
    DataUsageAgreement.create(model_id: "ref-id-123", data_source: "example", purpose: "example", consent_type: "example")
    updated = DataUsageAgreement.find(agg.id)
    expect(updated.status).to eq("draft")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("CreatedAgreement")
  end

  it "ActivateAgreement transitions to 'active'" do
    agg = DataUsageAgreement.create(
          model_id: "ref-id-123",
          data_source: "example",
          purpose: "example",
          consent_type: "example"
        )
    DataUsageAgreement.create(model_id: "ref-id-123", data_source: "example", purpose: "example", consent_type: "example")
    DataUsageAgreement.activate(agreement_id: agg.id, effective_date: Date.today, expiration_date: Date.today)
    updated = DataUsageAgreement.find(agg.id)
    expect(updated.status).to eq("active")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("ActivatedAgreement")
  end

  it "RevokeAgreement transitions to 'revoked'" do
    agg = DataUsageAgreement.create(
          model_id: "ref-id-123",
          data_source: "example",
          purpose: "example",
          consent_type: "example"
        )
    DataUsageAgreement.create(model_id: "ref-id-123", data_source: "example", purpose: "example", consent_type: "example")
    DataUsageAgreement.activate(agreement_id: agg.id, effective_date: Date.today, expiration_date: Date.today)
    DataUsageAgreement.revoke(agreement_id: agg.id)
    updated = DataUsageAgreement.find(agg.id)
    expect(updated.status).to eq("revoked")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("RevokedAgreement")
  end

  it "RenewAgreement transitions to 'active'" do
    agg = DataUsageAgreement.create(
          model_id: "ref-id-123",
          data_source: "example",
          purpose: "example",
          consent_type: "example"
        )
    DataUsageAgreement.create(model_id: "ref-id-123", data_source: "example", purpose: "example", consent_type: "example")
    DataUsageAgreement.activate(agreement_id: agg.id, effective_date: Date.today, expiration_date: Date.today)
    DataUsageAgreement.revoke(agreement_id: agg.id)
    DataUsageAgreement.renew(agreement_id: agg.id, expiration_date: Date.today)
    updated = DataUsageAgreement.find(agg.id)
    expect(updated.status).to eq("active")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("RenewedAgreement")
  end

  it "generates status predicates" do
    agg = DataUsageAgreement.create(
          model_id: "ref-id-123",
          data_source: "example",
          purpose: "example",
          consent_type: "example"
        )
    expect(agg.draft?).to be true
    expect(agg.active?).to be false
    expect(agg.revoked?).to be false
  end
end
