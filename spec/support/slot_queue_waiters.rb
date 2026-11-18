# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/codebase/heavy_slots"

# Waiters that line up for the one heavy-job place of a spec's own directory.
module SlotQueueWaiters
  # Holds the only place, starts each waiter once the one before it has its ticket, lets the place
  # go, and answers the names in the order the waiters ran.
  #
  # @param waiters [Array<Hash>] `name:` and, when given, the `base:` environment of each
  # @return [Array<Symbol>] the names in the order the waiters ran
  def run_waiters(waiters)
    order = []
    FileUtils.mkdir_p(dir)
    holder = File.new(File.join(dir, "slot-0.lock"), File::CREAT | File::RDWR)
    holder.flock(File::LOCK_EX)
    threads = waiters.each_with_index.map { |waiter, index| start(waiter, order).tap { await_ticket(index + 1) } }
    holder.close
    threads.each(&:join)
    order
  end

  def start(waiter, order)
    pause = ->(seconds) { ThreadParking.elapse(seconds / 50) }
    base = waiter.fetch(:base, {})
    slots = Hecks::Adapters::Codebase::HeavySlots.new(cap: 1, dir: dir, base: base, err: StringIO.new, pause: pause)
    Thread.new { slots.hold("gate") { order << waiter[:name] } }
  end

  def await_ticket(count)
    waiting = File.join(dir, "waiting")
    ThreadParking.wait_for { Dir.exist?(waiting) && Dir.children(waiting).size >= count }
  end
end
