require "hecks/hecks/adapters/work_limits"

# The committed Tickets world has the owner's stop switch off, so a booted registry refuses to
# start work. A group that exercises starting work includes this context to read the switch as on;
# the merge-window pause behind `roll_forward?` is left as it is.
RSpec.shared_context "with new work started" do
  before { allow(Hecks::Adapters::WorkLimits).to receive(:switch_on?).and_return(true) }
end
