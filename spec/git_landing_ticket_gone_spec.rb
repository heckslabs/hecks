require "spec_helper"
require "hecks/hecks/adapters/delivery_library"
Hecks::Adapters::DeliveryLibrary.require("git_landing")
require "tmpdir"

# A ticket file can vanish between a tidy and the read of its heartbeat; it then counts as gone.
RSpec.describe Hecks::Adapters::GitLanding::Ticket do
  let(:dir) { Dir.mktmpdir("hecks-ticket-gone") }

  after { FileUtils.remove_entry(dir) }

  it "reads a ticket removed before its heartbeat as infinitely silent" do
    ticket = described_class.create(File.join(dir, "a#{described_class::SUFFIX}"), { branch: "work/a" })
    File.delete(File.join(dir, "a#{described_class::SUFFIX}"))

    expect(ticket.silence(Time.now)).to eq(Float::INFINITY)
  end
end
