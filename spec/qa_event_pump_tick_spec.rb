require "spec_helper"
require "hecks/quality_control/cli/qa_tick"

# With its dial on, the tick runs the event pump as its last finding step; this pins that.
RSpec.describe Hecks::QualityControlCli::QaTick do
  let(:tick) { described_class.new(root: File.expand_path("../lib/hecks/quality_control", __dir__)) }
  let(:order) { [] }

  before do
    allow(tick).to receive(:dial) { |name, _fallback| %i[PUSH_NUDGE EVENT_PUMP].include?(name) }
    %i[run_pr_check run_sweep run_generated_domains run_mutation run_main_check run_push_nudge run_event_pump].each do |step|
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
