require_relative "../spec_helper"

RSpec.describe "Assessment lifecycle" do
  before { @app = Hecks.load(domain, force: true) }

  it "starts in 'pending' state" do
    agg = Assessment.initiate(model_id: "example", assessor_id: "example")
    expect(agg.status).to eq("pending")
  end

  it "InitiateAssessment transitions to 'pending'" do
    agg = Assessment.initiate(model_id: "example", assessor_id: "example")
    Assessment.initiate(model_id: "example", assessor_id: "example")
    updated = Assessment.find(agg.id)
    expect(updated.status).to eq("pending")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("InitiatedAssessment")
  end

  it "SubmitAssessment transitions to 'submitted'" do
    agg = Assessment.initiate(model_id: "example", assessor_id: "example")
    Assessment.initiate(model_id: "example", assessor_id: "example")
    Assessment.submit(assessment_id: agg.id, risk_level: "example", bias_score: 1.0, safety_score: 1.0, transparency_score: 1.0, overall_score: 1.0)
    updated = Assessment.find(agg.id)
    expect(updated.status).to eq("submitted")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("SubmittedAssessment")
  end

  it "RejectAssessment transitions to 'rejected'" do
    agg = Assessment.initiate(model_id: "example", assessor_id: "example")
    Assessment.initiate(model_id: "example", assessor_id: "example")
    Assessment.submit(assessment_id: agg.id, risk_level: "example", bias_score: 1.0, safety_score: 1.0, transparency_score: 1.0, overall_score: 1.0)
    Assessment.reject(assessment_id: agg.id)
    updated = Assessment.find(agg.id)
    expect(updated.status).to eq("rejected")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("RejectedAssessment")
  end

  it "generates status predicates" do
    agg = Assessment.initiate(model_id: "example", assessor_id: "example")
    expect(agg.pending?).to be true
    expect(agg.submitted?).to be false
    expect(agg.rejected?).to be false
  end
end
