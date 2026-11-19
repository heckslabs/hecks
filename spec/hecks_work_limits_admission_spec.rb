require "spec_helper"
require_relative "support/roll_forward_fixtures"
require "hecks/hecks/adapters/work_limits"

# With the `admission.signalbox` switch on, a start is cleared by Signalbox's admission, not the
# cap: the `WorkLimits` port asks the same rule the fill asked.
RSpec.describe Hecks::Adapters::WorkLimits do
  include RollForwardFixtures

  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }

  def admitting(reason) = double(reason: reason, clause: "admission by headroom 7000 MB")

  def started = [Struct.new(:work, :title, :status, :priority).new("tiles", "tiles", "started", "next")]

  def limits(reason)
    described_class.new(registry: registry_of(started, { signalbox: true }), settings: { admitting: admitting(reason) })
  end

  it "clears a start Signalbox admits, whatever the cap" do
    expect(limits(nil).check_cap(work: { value: "tiles" })[:output][:value]).to include("admitted by admission by headroom")
  end

  it "refuses a start Signalbox does not admit, naming the given" do
    expect { limits("skipped: signalbox: no room").check_cap(work: { value: "tiles" }) }.to raise_error(failure, /not admitted/)
  end
end
