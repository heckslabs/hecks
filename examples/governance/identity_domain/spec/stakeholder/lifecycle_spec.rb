require_relative "../spec_helper"

RSpec.describe "Stakeholder lifecycle" do
  before { @app = Hecks.load(domain, force: true) }

  it "starts in 'active' state" do
    agg = Stakeholder.register(
          name: "example",
          email: "example",
          role: "example",
          team: "example"
        )
    expect(agg.status).to eq("active")
  end

  it "RegisterStakeholder transitions to 'active'" do
    agg = Stakeholder.register(
          name: "example",
          email: "example",
          role: "example",
          team: "example"
        )
    Stakeholder.register(name: "example", email: "example", role: "example", team: "example")
    updated = Stakeholder.find(agg.id)
    expect(updated.status).to eq("active")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("RegisteredStakeholder")
  end

  it "DeactivateStakeholder transitions to 'deactivated'" do
    agg = Stakeholder.register(
          name: "example",
          email: "example",
          role: "example",
          team: "example"
        )
    Stakeholder.register(name: "example", email: "example", role: "example", team: "example")
    Stakeholder.deactivate(stakeholder_id: agg.id)
    updated = Stakeholder.find(agg.id)
    expect(updated.status).to eq("deactivated")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("DeactivatedStakeholder")
  end

  it "generates status predicates" do
    agg = Stakeholder.register(
          name: "example",
          email: "example",
          role: "example",
          team: "example"
        )
    expect(agg.active?).to be true
    expect(agg.deactivated?).to be false
  end
end
