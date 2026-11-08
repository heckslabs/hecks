# frozen_string_literal: true

require "timeout"

# Helpers for the Snapshot freeze examples: a movable clock, a source that fails once, and a wait
# that yields to the reading thread instead of guessing how long it needs.
module SnapshotFreezeWorld
  def clock = (@clock ||= [Time.utc(2026, 11, 7, 12, 0, 0)])

  def tick(seconds) = clock[0] += seconds

  def snapshot(source)
    @snap = Hecks::Adapters::PipelineBoard::Snapshot.new(source: source, every: 10, now: -> { clock.first }).start
  end

  def failing_then_good
    calls = 0
    lambda do
      calls += 1
      raise "gh exploded" if calls == 1

      { generated_at: "good", stages: [] }
    end
  end

  def until_held
    Timeout.timeout(5) { Thread.pass until yield }
  end

  def aged_by(seconds)
    snapshot(-> { { generated_at: "g" } })
    until_held { @snap.latest[:generated_at] == "g" }
    tick(seconds)
    @snap.latest
  end

  def after_failed_read
    snapshot(failing_then_good)
    until_held { @snap.latest[:refresh_error] }
    @snap.latest
  end

  def after_recovery
    after_failed_read
    @snap.refresh_now
    until_held { @snap.latest[:refresh_error].nil? && @snap.latest[:generated_at] == "good" }
    @snap.latest
  end
end
