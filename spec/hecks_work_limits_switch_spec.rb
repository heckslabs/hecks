require "spec_helper"
require_relative "support/roll_forward_fixtures"
require "hecks/hecks/adapters/work_limits"

# The owner's switch stops every start at the cap check, so a hand `Work.start!` is refused as the
# fill's own start is. A merge window is a separate pause and does not read as stopped.
RSpec.describe Hecks::Adapters::WorkLimits do
  include RollForwardFixtures

  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }

  def limits(world) = described_class.new(registry: registry_of([], world))

  it "refuses a start by name while the switch is off" do
    expect { limits({ roll_forward: false }).check_cap(work: { value: "a" }) }
      .to raise_error(failure, /new work is stopped/)
  end

  it "clears a start while the switch is on" do
    expect(limits({ roll_forward: true, cap: 2 }).check_cap(work: { value: "a" })[:output][:value]).to include("within the cap")
  end

  it "reads the switch as on when the world names none" do
    expect(described_class.switch_on?(nil)).to be(true)
  end
end
