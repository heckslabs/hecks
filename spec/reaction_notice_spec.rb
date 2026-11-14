require "spec_helper"
require "hecks/hecks/adapters/session_lookup"
require "hecks/hecks/adapters/run_gone"
require "hecks/hecks/adapters/run_activity"
require "hecks/hecks/adapters/claude_session_listing"
require "hecks/hecks/adapters/dispatching"
require "hecks/runtime/reaction_notice"

# A reaction's note is dropped when stderr is gone, so a chain that outlives its caller finishes.
RSpec.describe Hecks::Runtime::ReactionNotice do
  it "does not raise when stderr is gone" do
    allow(described_class).to receive(:warn).and_raise(Errno::EPIPE)

    expect { described_class.say("note") }.not_to raise_error
  end
end
