require_relative "../spec_helper"

RSpec.describe "Incident lifecycle" do
  before { @app = Hecks.load(domain, force: true) }

  it "starts in 'reported' state" do
    agg = Incident.report(
          model_id: "example",
          severity: "example",
          category: "example",
          description: "example",
          reported_by_id: "example"
        )
    expect(agg.status).to eq("reported")
  end

  it "ReportIncident transitions to 'reported'" do
    agg = Incident.report(
          model_id: "example",
          severity: "example",
          category: "example",
          description: "example",
          reported_by_id: "example"
        )
    Incident.report(model_id: "example", severity: "example", category: "example", description: "example", reported_by_id: "example")
    updated = Incident.find(agg.id)
    expect(updated.status).to eq("reported")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("ReportedIncident")
  end

  it "InvestigateIncident transitions to 'investigating'" do
    agg = Incident.report(
          model_id: "example",
          severity: "example",
          category: "example",
          description: "example",
          reported_by_id: "example"
        )
    Incident.report(model_id: "example", severity: "example", category: "example", description: "example", reported_by_id: "example")
    Incident.investigate(incident_id: agg.id)
    updated = Incident.find(agg.id)
    expect(updated.status).to eq("investigating")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("InvestigatedIncident")
  end

  it "MitigateIncident transitions to 'mitigating'" do
    agg = Incident.report(
          model_id: "example",
          severity: "example",
          category: "example",
          description: "example",
          reported_by_id: "example"
        )
    Incident.report(model_id: "example", severity: "example", category: "example", description: "example", reported_by_id: "example")
    Incident.investigate(incident_id: agg.id)
    Incident.mitigate(incident_id: agg.id)
    updated = Incident.find(agg.id)
    expect(updated.status).to eq("mitigating")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("MitigatedIncident")
  end

  it "ResolveIncident transitions to 'resolved'" do
    agg = Incident.report(
          model_id: "example",
          severity: "example",
          category: "example",
          description: "example",
          reported_by_id: "example"
        )
    Incident.report(model_id: "example", severity: "example", category: "example", description: "example", reported_by_id: "example")
    Incident.investigate(incident_id: agg.id)
    Incident.mitigate(incident_id: agg.id)
    Incident.resolve(incident_id: agg.id, resolution: "example", root_cause: "example")
    updated = Incident.find(agg.id)
    expect(updated.status).to eq("resolved")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("ResolvedIncident")
  end

  it "CloseIncident transitions to 'closed'" do
    agg = Incident.report(
          model_id: "example",
          severity: "example",
          category: "example",
          description: "example",
          reported_by_id: "example"
        )
    Incident.report(model_id: "example", severity: "example", category: "example", description: "example", reported_by_id: "example")
    Incident.investigate(incident_id: agg.id)
    Incident.mitigate(incident_id: agg.id)
    Incident.resolve(incident_id: agg.id, resolution: "example", root_cause: "example")
    Incident.close(incident_id: agg.id)
    updated = Incident.find(agg.id)
    expect(updated.status).to eq("closed")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("ClosedIncident")
  end

  it "generates status predicates" do
    agg = Incident.report(
          model_id: "example",
          severity: "example",
          category: "example",
          description: "example",
          reported_by_id: "example"
        )
    expect(agg.reported?).to be true
    expect(agg.investigating?).to be false
    expect(agg.mitigating?).to be false
  end
end
