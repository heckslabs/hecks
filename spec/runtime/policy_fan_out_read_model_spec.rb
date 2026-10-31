require "spec_helper"
require "tmpdir"

# A `for_each` policy may name a read model as its source. The fan-out then runs once per row of
# the read model's many-side head that the trigger addresses, each row keeping its own `id`.
RSpec.describe "a for_each policy over a read model" do
  READ_MODEL_SOURCE_FIXTURE = File.join(InMemoryDomain::ROOT, "spec/fixtures/policy_read_model_source.bluebook")

  def load_fixture(path)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT,
       InMemoryDomain::MEMORY_ADAPTER, InMemoryDomain::PRISM_ADAPTER, path].each { |file| Kernel.load(file) }
    end
    registry
  end

  # The fixture with its source replaced by `source`, from a scratch file.
  def booted(source = "Recipients")
    registry = Dir.mktmpdir do |dir|
      path = File.join(dir, "read_model_source.bluebook")
      File.write(path, File.read(READ_MODEL_SOURCE_FIXTURE).gsub("for_each \"Recipients\"", "for_each \"#{source}\""))
      load_fixture(path)
    end
    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let(:runtime) { booted }

  def open_section(code)
    runtime.dispatch_flat("ReadRoster::Section.OpenSection", code: { value: code })
  end

  def link(section, guardian)
    runtime.dispatch_flat("ReadRoster::Guardianship.LinkGuardian", id: "#{section}-#{guardian}",
                                                                  section: section, guardian: { value: guardian })
  end

  def announce(section)
    runtime.dispatch_flat("ReadRoster::Announcement.Send", id: "ann-#{section}", section: section)
  end

  def fan_out = runtime.reactions.select { |row| row[:policy] == "FanOutDeliveries" }

  def section_with_guardians(code, guardians)
    open_section(code)
    guardians.each { |guardian| link(code, guardian) }
  end

  it "fires the trigger once per row of the read model", :aggregate_failures do
    section_with_guardians("s1", %w[Ann Bo])

    announce("s1")

    expect(fan_out.size).to eq(2)
    expect(fan_out).to all(include(delivered: true))
  end

  it "fires nothing when the read model has no rows" do
    open_section("s2")

    announce("s2")

    expect(fan_out).to be_empty
  end

  it "refuses a source that is neither a query nor a read model, naming it" do
    unknown = booted("Nowhere")
    unknown.dispatch_flat("ReadRoster::Section.OpenSection", code: { value: "s3" })
    unknown.dispatch_flat("ReadRoster::Announcement.Send", id: "ann-x", section: "s3")

    expect(unknown.reactions.filter_map { |row| row[:reason] }.join).to include("\"Nowhere\" names no query or read model")
  end
end
