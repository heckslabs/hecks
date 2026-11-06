require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "../lib/hecks/hecks/adapters/rehearsal/inquiry"

# The rehearsal puts the decided edge through the same coverage check the mint raises before it
# writes an era, so a change no rule explains is refused in the rehearsal as it is at the mint.
RSpec.describe Hecks::Adapters::Rehearsal::Inquiry, "#examine coverage of the decided edge" do
  let(:manager) { Hecks::Adapters::PostgresRevision::LineageManager }
  let(:subject_double) do
    instance_double(Hecks::Adapters::Rehearsal::Subject, registry: :registry, bluebook: :bluebook,
                                                         held: instance_double(Hecks::Adapters::JournalStore::HeldDomain))
  end
  let(:store) { instance_double(Hecks::Adapters::Rehearsal::MemoryStore, eras: [{ label: "aaaaaa" }]) }
  let(:inquiry) { described_class.new(subject_double, store) }
  let(:edge) { :edge }

  before do
    allow(subject_double.held).to receive(:named) { |era| era }
    allow(manager).to receive(:held_bluebook).and_return(:held)
  end

  it "refuses with the words the mint raises when the check does", :aggregate_failures do
    allow(manager).to receive(:check_coverage!).and_raise(Hecks::Runtime::WiringError, "cannot boot X: :target is not explained")
    expect(inquiry.send(:coverage_refusals, edge)).to eq(["cannot boot X: :target is not explained"])
    expect(manager).to have_received(:check_coverage!).with(:registry, :bluebook, :held, edge)
  end

  it "refuses nothing when the check passes" do
    allow(manager).to receive(:check_coverage!)
    expect(inquiry.send(:coverage_refusals, edge)).to eq([])
  end

  it "checks nothing when no edge was decided" do
    allow(manager).to receive(:check_coverage!)
    inquiry.send(:coverage_refusals, nil)
    expect(manager).not_to have_received(:check_coverage!)
  end
end
