require_relative "../spec_helper"

RSpec.describe "RegulatoryFramework lifecycle" do
  before { @app = Hecks.load(domain, force: true) }

  it "starts in 'draft' state" do
    agg = RegulatoryFramework.register(
          name: "example",
          jurisdiction: "example",
          version: "example",
          authority: "example"
        )
    expect(agg.status).to eq("draft")
  end

  it "RegisterFramework transitions to 'draft'" do
    agg = RegulatoryFramework.register(
          name: "example",
          jurisdiction: "example",
          version: "example",
          authority: "example"
        )
    RegulatoryFramework.register(name: "example", jurisdiction: "example", version: "example", authority: "example")
    updated = RegulatoryFramework.find(agg.id)
    expect(updated.status).to eq("draft")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("RegisteredFramework")
  end

  it "ActivateFramework transitions to 'active'" do
    agg = RegulatoryFramework.register(
          name: "example",
          jurisdiction: "example",
          version: "example",
          authority: "example"
        )
    RegulatoryFramework.register(name: "example", jurisdiction: "example", version: "example", authority: "example")
    RegulatoryFramework.activate(framework_id: agg.id, effective_date: Date.today)
    updated = RegulatoryFramework.find(agg.id)
    expect(updated.status).to eq("active")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("ActivatedFramework")
  end

  it "RetireFramework transitions to 'retired'" do
    agg = RegulatoryFramework.register(
          name: "example",
          jurisdiction: "example",
          version: "example",
          authority: "example"
        )
    RegulatoryFramework.register(name: "example", jurisdiction: "example", version: "example", authority: "example")
    RegulatoryFramework.activate(framework_id: agg.id, effective_date: Date.today)
    RegulatoryFramework.retire(framework_id: agg.id)
    updated = RegulatoryFramework.find(agg.id)
    expect(updated.status).to eq("retired")
    event_names = @app.events.map { |e| e.class.name.split("::").last }
    expect(event_names).to include("RetiredFramework")
  end

  it "generates status predicates" do
    agg = RegulatoryFramework.register(
          name: "example",
          jurisdiction: "example",
          version: "example",
          authority: "example"
        )
    expect(agg.draft?).to be true
    expect(agg.active?).to be false
    expect(agg.retired?).to be false
  end
end
