require "spec_helper"

# The hecksagon picks the class that keeps a `Postgres` domain's rows (ADR 0182): the table layout,
# or with `revisions true` the revision layout. The choice is read from the registry's hecksagons,
# so the spec stands in a registry that answers only that, and never connects to a database.
RSpec.describe "revisions, choosing the Postgres layout" do
  let(:layout) { Hecks::Ports::Persistence::Layout }

  def hecksagon(revisions: false, attaches: [], root_binds: [])
    instance_double(Hecks::Bluebook::Hecksagon, revisions?: revisions, default_binds: root_binds,
                                                 attaches?: false).tap do |double|
      attaches.each { |name| allow(double).to receive(:attaches?).with(name).and_return(true) }
    end
  end

  def registry_with(hecksagons)
    registry = instance_double(Hecks::Runtime::Registry, hecksagons: hecksagons)
    allow(registry).to receive(:hecksagon) { |name| hecksagons[name.to_s] }
    allow(registry).to receive(:adapter_class) { |name| Hecks::Adapters.const_get(name) }
    registry
  end

  it "builds the revision layout for Postgres when the hecksagon says revisions true" do
    registry = registry_with("Lending" => hecksagon(revisions: true))

    expect(layout.adapter_class(registry, "Lending", "Postgres")).to eq(Hecks::Adapters::PostgresEra)
  end

  it "keeps the table layout for Postgres when revisions is left out" do
    registry = registry_with("Lending" => hecksagon)

    expect(layout.adapter_class(registry, "Lending", "Postgres")).to eq(Hecks::Adapters::Postgres)
  end

  it "leaves any other adapter's class alone, whatever the hecksagon says" do
    registry = registry_with("Lending" => hecksagon(revisions: true))

    expect(layout.adapter_class(registry, "Lending", "Memory")).to eq(Hecks::Adapters::Memory)
  end

  it "hands revisions to a bluebook the domain attaches and gives its root default" do
    root = Hecks::Bluebook::Bind.new(aggregate: nil, verb: "persisted_by", adapter: "Postgres")
    registry = registry_with("Lending" => hecksagon(revisions: true, attaches: ["Governance"], root_binds: [root]))

    expect(layout.revisions?(registry, "Governance")).to be(true)
  end

  it "keeps revisions from an attached bluebook the domain gives no root default" do
    registry = registry_with("Lending" => hecksagon(revisions: true, attaches: ["Governance"]))

    expect(layout.revisions?(registry, "Governance")).to be(false)
  end
end
