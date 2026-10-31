require "spec_helper"
require "tmpdir"

# A `for_each` query argument named after a `reference_to` the emitting aggregate declares is
# lent that record's stored reference. A payload value is never overridden, and an argument with
# no matching reference is left alone.
RSpec.describe "a for_each query argument lent from the emitting record's reference" do
  EMITTER_REFERENCE_FIXTURE = File.join(InMemoryDomain::ROOT, "spec/fixtures/policy_emitter_reference.bluebook")

  def load_fixture(path)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT,
       InMemoryDomain::MEMORY_ADAPTER, InMemoryDomain::PRISM_ADAPTER, path].each { |file| Kernel.load(file) }
    end
    registry
  end

  def booted
    registry = load_fixture(EMITTER_REFERENCE_FIXTURE)
    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let(:runtime) do
    booted.tap do |bound|
      bound.dispatch_flat("EmitterReference::Section.Open", code: { value: "s1" })
      bound.dispatch_flat("EmitterReference::Section.Open", code: { value: "s2" })
      bound.dispatch_flat("EmitterReference::Enrollment.Enroll", code: { value: "e-1" }, section: "s1")
      bound.dispatch_flat("EmitterReference::Enrollment.Enroll", code: { value: "e-2" }, section: "s1")
      bound.dispatch_flat("EmitterReference::Enrollment.Enroll", code: { value: "e-3" }, section: "s2")
      bound.dispatch_flat("EmitterReference::Message.Compose", code: { value: "m-1" }, section: "s1")
    end
  end

  def fan_out(policy) = runtime.reactions.select { |row| row[:policy] == policy }

  def send_message = runtime.dispatch_flat("EmitterReference::Message.Send", message: "m-1")

  def redirect_message(section)
    runtime.dispatch_flat("EmitterReference::Message.Redirect", message: "m-1", section: section)
  end

  it "fills the query's section from the emitter's stored reference, fanning out per enrollment", :aggregate_failures do
    send_message

    expect(fan_out("QueueOnSend").size).to eq(2)
    expect(fan_out("QueueOnSend")).to all(include(delivered: true))
  end

  it "keeps a payload value over the emitter's stored reference" do
    redirect_message("s2")

    expect(fan_out("QueueOnRedirect").size).to eq(1)
  end

  # The query's `group` is unfilled, so it matches every enrollment, the section's e-3 included.
  it "leaves an argument with no matching reference unfilled" do
    send_message

    expect(fan_out("QueueOnGroup").find { |row| row[:for_row] == "e-3" }).to include(delivered: true)
  end
end
