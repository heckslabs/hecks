require_relative "../../spec_helper"

RSpec.describe RiskAssessmentDomain::Assessment::Events::RecordedFinding do
  subject(:event) { described_class.new(
          aggregate_id: "example",
          assessment_id: "example",
          category: "example",
          severity: "example",
          description: "example",
          model_id: "example",
          assessor_id: "example",
          risk_level: "low",
          bias_score: 1.0,
          safety_score: 1.0,
          transparency_score: 1.0,
          overall_score: 1.0,
          submitted_at: DateTime.now,
          findings: [],
          mitigations: [],
          status: "example"
        ) }

  it "is frozen" do
    expect(event).to be_frozen
  end

  it "records when it occurred" do
    expect(event.occurred_at).to be_a(Time)
  end

  it "carries aggregate_id" do
    expect(event.aggregate_id).to eq("example")
  end

  it "carries assessment_id" do
    expect(event.assessment_id).to eq("example")
  end

  it "carries category" do
    expect(event.category).to eq("example")
  end

  it "carries severity" do
    expect(event.severity).to eq("example")
  end

  it "carries description" do
    expect(event.description).to eq("example")
  end

  it "carries model_id" do
    expect(event.model_id).to eq("example")
  end

  it "carries assessor_id" do
    expect(event.assessor_id).to eq("example")
  end

  it "carries risk_level" do
    expect(event.risk_level).to eq("low")
  end

  it "carries bias_score" do
    expect(event.bias_score).to eq(1.0)
  end

  it "carries safety_score" do
    expect(event.safety_score).to eq(1.0)
  end

  it "carries transparency_score" do
    expect(event.transparency_score).to eq(1.0)
  end

  it "carries overall_score" do
    expect(event.overall_score).to eq(1.0)
  end

  it "carries submitted_at" do
    expect(event.submitted_at).not_to be_nil
  end

  it "carries findings" do
    expect(event.findings).to eq([])
  end

  it "carries mitigations" do
    expect(event.mitigations).to eq([])
  end

  it "carries status" do
    expect(event.status).to eq("example")
  end
end
