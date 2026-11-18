require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# Whether a work item's landing job is still running: the newest `Landing` row naming its branch
# is `requested`, the branch named with QA's prefix or not.
RSpec.describe Hecks::Adapters::Dispatching::WorkItems, "#landing_in_flight?" do
  let(:registry) { boot_hecks_in_memory.registry }

  def pending?(landings, key)
    held = Struct.new(:all).new(landings)
    allow(registry).to receive(:repository).and_wrap_original do |original, domain, aggregate|
      aggregate.hecks_name == "Landing" ? held : original.call(domain, aggregate)
    end
    described_class.new(registry).landing_in_flight?(key)
  end

  def row(branch, status) = { branch: branch, landed: "", status: status }

  it "is true while the job for the branch, QA's prefix included, is requested" do
    expect(pending?([row("qa/a", "requested")], "a")).to be(true)
  end

  it "is false once the job was refused" do
    expect(pending?([row("a", "refused")], "a")).to be(false)
  end

  it "is false when a dead job's requested row is followed by a newer refused one" do
    expect(pending?([row("a", "requested"), row("a", "refused")], "a")).to be(false)
  end

  it "is true when a dead job's requested row is followed by a fresh submission" do
    expect(pending?([row("a", "refused"), row("a", "requested")], "a")).to be(true)
  end
end
