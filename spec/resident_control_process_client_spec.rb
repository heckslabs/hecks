require "spec_helper"
require "hecks/adapters/driving/resident/client"

# A worktree's control line goes to the control process, the primary checkout's resident, and
# never to a resident of the worktree's own; with it down the line starts cold and says so.
RSpec.describe "a control line and the control process" do
  before do
    require_relative "support/control_process_checkouts"
    extend ControlProcessCheckouts

    build_checkouts
    allow(Hecks::Adapters::Driving::Resident::Paths).to receive(:recall_words).with("control").and_return(%w[work agent])
    allow(Hecks::Adapters::Driving::Resident::Stuck).to receive(:after)
    allow(client).to receive(:spawn_resident).and_return("started")
  end

  let(:client) { Hecks::Adapters::Driving::Resident::Client }

  after { remove_checkouts }

  def launch(*argv)
    stub_const("ARGV", argv)
    client.attempt(own, File.join(own, "exe", "hecks"))
  rescue SystemExit => e
    e.status
  end

  it "asks the primary and never the worktree's own resident", :aggregate_failures do
    allow(client).to receive(:ask).and_return([0, nil])
    launch("tickets", "Work.undone")
    expect(client).to have_received(:ask).with(primary, anything).once
    expect(client).not_to have_received(:ask).with(own, anything)
  end

  it "says the control process is down, and runs cold, when the primary answers nothing" do
    allow(client).to receive(:ask).and_return([nil, nil])
    expect { launch("tickets", "Work.undone") }.to output(/control process down.*cold/).to_stderr
  end
end
