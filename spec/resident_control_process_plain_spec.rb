require "spec_helper"

# A resident that is not the control process still goes idle after the idle time.
RSpec.describe "a plain resident beside the control process" do
  before do
    require_relative "support/control_process_checkouts"
    extend ControlProcessCheckouts

    require_relative "support/control_process_server"
    extend ControlProcessServer

    build_checkouts
  end

  let(:server) { judging_server(false) }

  after { remove_checkouts }

  it "goes idle after the idle time" do
    quiet_for_a_while
    expect(server.send(:idle?)).to be(true)
  end
end
