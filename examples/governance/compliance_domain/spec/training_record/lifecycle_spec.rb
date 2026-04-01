require_relative "../spec_helper"

RSpec.describe "TrainingRecord lifecycle" do
  before { @app = Hecks.load(domain, force: true) }

  it "starts in 'assigned' state" do
    agg = TrainingRecord.assign_training(stakeholder_id: "example", policy_id: "ref-id-123")
    expect(agg.status).to eq("assigned")
  end

  it "AssignTraining transitions to 'assigned'" do
    agg = TrainingRecord.assign_training(stakeholder_id: "example", policy_id: "ref-id-123")
    TrainingRecord.assign_training(stakeholder_id: "example", policy_id: "ref-id-123")
    updated = TrainingRecord.find(agg.id)
    expect(updated.status).to eq("assigned")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("AssignedTraining")
  end

  it "CompleteTraining transitions to 'completed'" do
    agg = TrainingRecord.assign_training(stakeholder_id: "example", policy_id: "ref-id-123")
    TrainingRecord.assign_training(stakeholder_id: "example", policy_id: "ref-id-123")
    TrainingRecord.complete_training(training_record_id: agg.id, certification: "example", expires_at: Date.today)
    updated = TrainingRecord.find(agg.id)
    expect(updated.status).to eq("completed")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("CompletedTraining")
  end

  it "RenewTraining transitions to 'completed'" do
    agg = TrainingRecord.assign_training(stakeholder_id: "example", policy_id: "ref-id-123")
    TrainingRecord.assign_training(stakeholder_id: "example", policy_id: "ref-id-123")
    TrainingRecord.complete_training(training_record_id: agg.id, certification: "example", expires_at: Date.today)
    TrainingRecord.renew_training(training_record_id: agg.id, certification: "example", expires_at: Date.today)
    updated = TrainingRecord.find(agg.id)
    expect(updated.status).to eq("completed")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("RenewedTraining")
  end

  it "generates status predicates" do
    agg = TrainingRecord.assign_training(stakeholder_id: "example", policy_id: "ref-id-123")
    expect(agg.assigned?).to be true
    expect(agg.completed?).to be false
  end
end
