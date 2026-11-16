require "spec_helper"
require "hecks/hecks/adapters/ticking"

# A watcher on a clock and a child of its own: nothing is started, and the child ends when told.
module TickingWatcherHelpers
  def now = (@now ||= [100.0])

  def started = (@started ||= [])

  def exited = (@exited ||= [false])

  def watcher
    spawn = ->(*argv) { started << argv }
    @watcher ||= Hecks::Adapters::Ticking::Watcher.new("train/main-abc", clock: -> { now.first }, spawn: spawn,
                                                                         reap: ->(_pid) { exited.first })
  end

  def exit_at(time)
    now[0] = time
    exited[0] = true
  end
end

# One child waits on a pull request's checks; its exit is the event, and an exit at once is a
# failure to watch, not a result.
RSpec.describe Hecks::Adapters::Ticking::Watcher do
  include TickingWatcherHelpers

  it "starts one `gh pr checks --watch` on the branch" do
    watcher.start
    expect(started).to eq([["gh", "pr", "checks", "train/main-abc", "--watch", "--interval", "60"]])
  end

  it "is done when the child ends after watching" do
    watcher.start
    exit_at(400.0)
    expect(watcher.poll).to eq(:done)
  end

  it "failed when the child ends at once" do
    watcher.start
    exit_at(101.0)
    expect(watcher.poll).to eq(:failed)
  end

  it "failed when gh cannot start" do
    failing = described_class.new("b", clock: -> { 0 }, spawn: ->(*) { raise Errno::ENOENT })
    expect(failing.start).to eq(:failed)
  end
end
