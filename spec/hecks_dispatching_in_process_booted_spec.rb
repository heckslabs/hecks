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

  it "does not fail a step whose reaction starts a roll that is refused", :aggregate_failures do
    planned = Hecks::Adapters::Dispatching::Filling.during(true) do
      runner.call(["tickets", "Work.plan!", "work.value=nested", "title.value=N", "--wait"])
    end

    expect(planned.ok?).to be(true)
    expect(roll_statuses).to include("refused")
  end

  # The status of every Roll the reactions recorded.
  def roll_statuses
    aggregate = registry.bluebook("Hecks").aggregates.find { |candidate| candidate.hecks_name == "Roll" }
    registry.repository("Hecks", aggregate).all.map { |roll| Hecks::Adapters::StartedWork.value(roll, :status).to_s }
  end

  it "answers a line the domain refuses as a failed line with the reason", :aggregate_failures do
    result = runner.call(["tickets", "Work.start!", "to=no-such-work", "claimed_by.value=dispatch", "--wait"])

    expect(result.ok?).to be(false)
    expect(result.err).to include("absent_argument", "claimed_at")
  end
end
