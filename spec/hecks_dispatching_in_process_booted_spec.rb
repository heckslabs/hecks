require "spec_helper"
require "json"
require "hecks/hecks/adapters/dispatching"

# The runner against a booted domain, as the launcher boots it in Memory.
RSpec.describe Hecks::Adapters::Dispatching::InProcessRunner do
  let(:registry) { boot_hecks_in_memory(File.expand_path("../lib/hecks/hecks", __dir__)).registry }
  let(:runner) { described_class.new(registry) }

  it "answers a query the way the launcher prints it", :aggregate_failures do
    result = runner.call(["tickets", "Work.undone"])

    expect(result.ok?).to be(true)
    expect(JSON.parse(result.out[/\[.*\]/m])).to eq([])
  end

  it "answers a line the domain refuses as a failed line with the reason", :aggregate_failures do
    result = runner.call(["tickets", "Work.start!", "to=no-such-work", "claimed_by.value=dispatch", "--wait"])

    expect(result.ok?).to be(false)
    expect(result.err).to include("absent_argument", "claimed_at")
  end
end
