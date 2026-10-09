require "spec_helper"
require "tmpdir"

# A `for_each` policy's `with:` may name the fan-out row's own fields. The row's fields sit below
# the event payload and the emitter's identity in the projection's scope, and are never offered to
# a trigger that declares no `with:`.
RSpec.describe "a for_each policy's projection over the fan-out row" do
  ROW_FIELDS_FIXTURE = File.join(InMemoryDomain::ROOT, "spec/fixtures/policy_row_fields.bluebook")

  def load_fixture(path)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT,
       InMemoryDomain::MEMORY_ADAPTER, InMemoryDomain::PRISM_ADAPTER, path].each { |file| Kernel.load(file) }
    end
    registry
  end

  def booted
    registry = load_fixture(ROW_FIELDS_FIXTURE)
    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let(:runtime) do
    booted.tap do |bound|
      bound.dispatch_flat("RowFields::Permit.Grant", code: { value: "p-1" }, holder: { value: "h-1" }, limit: { value: 40 })
    end
  end

  def cap_of(code)
    permit = runtime.registry.bluebook("RowFields").aggregate("Permit")
    runtime.registry.repository("RowFields", permit).find(code)[:cap]&.then { |cap| cap[:value] }
  end

  def report = runtime.dispatch_flat("RowFields::Breach.Report", ref: { value: "b-1" }, holder: { value: "h-1" })

  def report_limited
    runtime.dispatch_flat("RowFields::Breach.ReportLimited", ref: { value: "b-2" }, holder: { value: "h-1" }, limit: { value: 7 })
  end

  def reasons = runtime.reactions.filter_map { |row| row[:reason] }

  # The fixture with its projection reading `source` instead of `:limit`, from a scratch file.
  def load_reading(source)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "row_fields.bluebook")
      File.write(path, File.read(ROW_FIELDS_FIXTURE).gsub("cap: :limit", "cap: :#{source}"))
      load_fixture(path)
    end
  end

  it "delivers a row field the projection names", :aggregate_failures do
    report

    expect(reasons).to be_empty
    expect(cap_of("p-1")).to eq(40)
  end

  it "lets the event payload win over a row field of the same name" do
    report_limited

    expect(cap_of("p-1")).to eq(7)
  end

  it "offers an unprojected trigger only the payload and the row key, never the row's fields" do
    runtime.registry.bluebook("RowFields").policies.find { |p| p.name == "CapFromRow" }.instance_variable_set(:@with_spec, [])

    report

    expect(reasons.join).not_to include("code")
  end

  it "accepts a with: name that is a field of the for_each query's aggregate" do
    expect { load_reading(:limit) }.not_to raise_error
  end

  it "still refuses a with: name that is neither the payload, the identity nor a row field" do
    expect { load_reading(:nonsense) }.to raise_error(Hecks::Bluebook::DSL::Malformed, /reads :nonsense/)
  end
end
