# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/claude_cleaning"

# With the owner's `reaping.signalbox` switch on, a reap is Signalbox's: the pass is cleared
# first, then each row of Roundhouse's `Ended` meter is put to `Reaping.Rule` on a standalone
# Signalbox, and only what it rules reaped is removed. The listing is the one prune_sessions.sh and
# PlainSweep judged; each example names where Signalbox differs from them.
RSpec.describe Hecks::Adapters::ClaudeCleaning::SignalboxReap do
  # Signalbox's own rulings, with the clearance a test gives (nil: cleared).
  def door(clearance = nil)
    ruler = Hecks::Adapters::Dispatching::SignalboxDoor.new
    double(reap_clearance: clearance, setting: {}).tap do |held|
      allow(held).to receive(:reap_refusal) { |facts| ruler.reap_refusal(facts) }
    end
  end

  # A meter row; `given` overrides the kind, state, role, idle minutes, run and run status.
  def session(id, **given)
    row = { id: id, session: "#{id}-full", name: id, state: "done", kind: "finished", live: "no", idle_minutes: 12,
            role: "helper", run: "", run_status: "", cwd: "/repo" }
    row.merge(given.transform_keys { |key| key == :idle ? :idle_minutes : key })
  end

  def copy(branch, landed:, held: "no")
    { path: "/repo/.claude/worktrees/#{branch}", branch: branch, landed: landed, unsaved: 0, idle_minutes: 60, held: held }
  end

  def window(pinned)
    double.tap { |held| allow(held).to receive(:pin) { |entry| pinned.include?(entry["id"]) ? "pinned" : nil } }
  end

  def jobs(owner)
    double.tap { |held| allow(held).to receive(:launched_by) { |id| owner.include?(id) ? "" : "coordinator:reap" } }
  end

  def facts(unsaved: 0, pinned: [], owner: [])
    sources = Hecks::Adapters::ClaudeCleaning::ReapFacts::Sources.new(
      window: window(pinned), jobs: jobs(owner), transcript: double(taken_over?: false, worktree: unsaved.zero? ? "" : Dir.pwd),
      worktrees: double(uncommitted: unsaved, ahead: 0), runs: double(started: [], runs: {})
    )
    Hecks::Adapters::ClaudeCleaning::ReapFacts.new(sources, ended_minutes: 5, owner_minutes: 1440, fuses: { helper_minutes: 30 })
  end

  def reap(rows, copies: [], clearance: nil, **known)
    described_class.new(door: door(clearance), meter: -> { { sessions: rows, copies: copies } }, facts: facts(**known),
                        remove: ->(_id) {}, retire: ->(_path) {})
  end

  # prune_sessions.sh removed it; PlainSweep waits the Hecks world's 30 minutes.
  it "removes a finished helper past its 5-minute ended window" do
    expect(reap([session("a1b2")]).call.removed).to eq(["a1b2"])
  end

  it "keeps a finished helper inside its ended window, naming the given" do
    expect(reap([session("c3d4", idle: 2)]).call.kept)
      .to eq([["c3d4", "a session is reaped only once it has been idle its keep window"]])
  end

  it "never reaps the standing orchestrator seat" do
    expect(reap([session("134d", role: "orchestrator", idle: 90)]).call.kept.map(&:first)).to eq(["134d"])
  end

  it "never reaps a session whose run is still started, as prune_sessions.sh skipped it" do
    expect(reap([session("f1e2", role: "coder", idle: 90, run: "w", run_status: "started")]).call.removed).to be_empty
  end

  it "keeps a pinned session" do
    expect(reap([session("c9d0", idle: 90)], pinned: ["c9d0"]).call.kept).to eq([["c9d0", "a pinned session is never reaped"]])
  end

  it "keeps a session whose worktree holds unsaved work" do
    expect(reap([session("a7b8", idle: 90)], unsaved: 2).call.kept)
      .to eq([["a7b8", "a session with unsaved work is never reaped"]])
  end

  # prune_sessions.sh removed an owner's done session at once; Signalbox keeps it a day.
  it "keeps an owner's own ended session its day" do
    expect(reap([session("e5f6", idle: 90)], owner: ["e5f6"]).call.removed).to be_empty
  end

  # Neither script reaped this: a helper listed blocked whose process is gone.
  it "removes a stale helper past its fuse's time rating" do
    expect(reap([session("b3c4", kind: "stale", state: "blocked", idle: 45)]).call.removed).to eq(["b3c4"])
  end

  # pass.sh retired a merged worktree no started item named, as Signalbox does.
  it "retires a landed copy and keeps one whose branch main lacks", :aggregate_failures do
    done = reap([], copies: [copy("tiles", landed: "yes"), copy("adr", landed: "no")]).call
    expect(done.retired).to eq(["tiles"])
    expect(done.kept).to eq([["adr", "a copy is reaped only once its branch is on main"]])
  end

  it "keeps a landed copy a live session works in" do
    expect(reap([], copies: [copy("mine", landed: "yes", held: "yes")]).call.retired).to be_empty
  end

  it "removes nothing from a copy Signalbox does not clear, and says why" do
    expect(reap([session("a1b2")], clearance: "a part acts on shared state only from the head of main").report)
      .to eq("signalbox reap refused: a part acts on shared state only from the head of main; nothing removed")
  end

  it "rules without removing when asked for its verdicts" do
    removed = []
    pass = described_class.new(door: door, meter: -> { { sessions: [session("a1b2")], copies: [] } }, facts: facts,
                               remove: ->(id) { removed << id }, retire: ->(_path) {})
    expect([pass.verdicts.removed, removed]).to eq([["a1b2"], []])
  end

  it "reports what it removed and kept on one line" do
    expect(reap([session("a1b2"), session("c9d0", idle: 90)], pinned: ["c9d0"]).report)
      .to eq("signalbox reaped 1 session(s) and 0 copy(ies); kept 1: c9d0 (a pinned session is never reaped)")
  end
end
