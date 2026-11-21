require "spec_helper"
require_relative "support/registry_double"
require "hecks/hecks/adapters/work_notes"

# The WorkNotes port's adapter against a stubbed Work repository: the detail with a dated note
# after it.
RSpec.describe Hecks::Adapters::WorkNotes do
  include RegistryDouble

  def composed(detail, key = "w1")
    registry = registry_double
    allow(registry).to receive(:repository).and_return(Struct.new(:all).new([{ work: "w1", detail: detail }]))
    allow(Hecks::Adapters::StartedWork).to receive(:work_aggregate).and_return(Object.new)
    described_class.new(registry: registry)
                   .compose_note(work: { value: key }, note: { value: "waits" }, dated: { value: "2026-11-20" })
  end

  it "puts the dated note after the detail, a blank line between" do
    expect(composed("why")).to eq(detail: { value: "why\n\n2026-11-20: waits" })
  end

  it "starts the detail with the note when there is none" do
    expect(composed("")).to eq(detail: { value: "2026-11-20: waits" })
  end

  it "refuses by name a work item that is not recorded" do
    expect { composed("why", "nope") }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /no work item is named nope/)
  end
end
