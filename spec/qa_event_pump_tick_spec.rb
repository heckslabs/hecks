require "spec_helper"
require "hecks/quality_control/cli/qa_tick"

# The tick runs the event pump as its last finding step, so a pump that is later than any other step
# is what this example pins.
RSpec.describe Hecks::QualityControlCli::QaTick do
  let(:tick) { described_class.new(root: File.expand_path("../lib/hecks/quality_control", __dir__)) }
  let(:order) { [] }

  before do
    %i[run_pr_check run_sweep run_generated_domains run_mutation run_main_check run_event_pump].each do |step|
      allow(tick).to receive(step) do
        order << step
        ["", 0]
      end
    end
  end

  it "runs the event pump after every other finding step" do
    tick.send(:finding_steps)

    expect(order.last).to eq(:run_event_pump)
  end
end
