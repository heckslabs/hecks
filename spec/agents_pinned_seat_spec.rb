require "spec_helper"
require "tmpdir"
require_relative "support/agents_hand_run_watch_helpers"

# A standing seat that is listed registers itself under its role's run key on a beat of the clock:
# the first time, and again when its session id changes, with no hand step.
RSpec.describe "a pinned role registering itself" do
  include AgentsHandRunWatchHelpers

  let(:jobs) { Dir.mktmpdir }

  before { boot_watch }

  after { FileUtils.remove_entry(jobs) }

  def watch_adapter = Hecks::Adapters::HandRunWatch.new(listing: -> { sessions }, jobs: jobs)

  def pin(*ids) = File.write(File.join(jobs, "pins.json"), JSON.generate(ids))

  it "registers a listed architect under the key architect" do
    sessions << session_entry("a4c4-first-full", "architect")
    beat("b1")
    expect(hand("architect").session.value).to eq("a4c4-first-full")
  end

  it "registers the new session id under the same key when the seat's id changes" do
    sessions << session_entry("a4c4-first-full", "architect")
    beat("b1")
    sessions.replace([session_entry("a4c4-second-full", "architect")])
    beat("b2")
    expect(hand("architect").session.value).to eq("a4c4-second-full")
  end

  it "prefers the pinned session when two are listed under the role" do
    sessions.push(session_entry("0000-plain-full", "lead"), session_entry("1ead-pinned-full", "lead"))
    pin("1ead-pin")
    beat("b1")
    expect(hand("lead").session.value).to eq("1ead-pinned-full")
  end

  it "registers a session the pipeline did not launch only, never a dispatched architect" do
    sessions << session_entry("d15a-full", "architect:p-walk")
    beat("b1")
    expect(Hecks::Agents::HandRun.find("architect")).to be_nil
  end
end
