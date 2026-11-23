require "spec_helper"
require "hecks/agents/adapters/fleet_control"
require_relative "support/agents_fleet_helpers"

# A seat is woken by the run key that holds it: in its own session, with the line telling it to read
# its inbox, and never when it is working or when no session holds the key. Every session here is a
# stand-in; no `claude` command is run.
RSpec.describe "waking a seat of the Agents fleet" do
  include AgentsFleetHelpers

  # A shell whose resume prints the note of a copy.
  class CopyingShell < AgentsFleetHelpers::RecordingShell
    def capture(*command, **)
      return super unless command.include?("--resume")

      Hecks::Adapters::Shell::Result.new("", "note: started a copy as zzzz9999", Struct.new(:success?).new(true))
    end
  end

  before do
    boot_fleet
    shell.listing << { "id" => "eeee5555", "sessionId" => "eeee5555-full", "name" => "architect",
                       "state" => "working", "status" => "idle" }
  end

  after { FileUtils.rm_rf(projects) }

  it "wakes the idle session that holds the run key, in place", :aggregate_failures do
    expect(steer(:wake!, "fix-it").status).to eq("woken")
    expect(shell.commands.last[:command]).to include("--bg", "--resume", "aaaa1111-full")
  end

  it "tells the seat to read its inbox" do
    steer(:wake!, "fix-it")
    expect(shell.commands.last[:command].last).to include("Message.inbox recipient.value=fix-it")
  end

  it "wakes a session listed idle whose state still says working" do
    expect(steer(:wake!, "architect").status).to eq("woken")
  end

  it "refuses a seat that is working, running no command", :aggregate_failures do
    expect(steer(:wake!, "orchestrator").refusal.value).to include("is working")
    expect(shell.commands).to be_empty
  end

  it "refuses by name when no session holds the key" do
    expect(steer(:wake!, "nobody").refusal.value).to include("no session holds the run key nobody")
  end

  it "refuses a wake that started a copy, naming the copy" do
    @shell = CopyingShell.new(listing)
    expect(steer(:wake!, "fix-it").refusal.value).to include("started a copy as zzzz9999")
  end
end
