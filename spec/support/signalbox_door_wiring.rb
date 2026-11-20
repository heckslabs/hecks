# frozen_string_literal: true

require "hecks/hecks/adapters/dispatching"
require "hecks/signalbox/adapters/replayed_looking"
require "hecks/signalbox/adapters/replayed_pressure_posting"

# A {Hecks::Adapters::Dispatching::SignalboxDoor} over a Signalbox booted in Memory, whose beat
# looks from a given view at the quiet machine of `ReplayedLooking`, beside a posted signal.
module SignalboxDoorWiring
  # The view of a linked worktree: its head is not main's tip.
  WORKTREE = Hecks::Adapters::ReplayedLooking::MAIN.merge(head: "9b81245").freeze

  # @param age [Integer] seconds since the signal was posted
  # @return [Hash] a posted signal in the normal band with 11000 MB of headroom
  def posted(age: 30) = { band: "normal", headroom: 11_000, posted_at: (Time.now - age).utc.iso8601, stale_after: 120 }

  # @param view [Hash] the copy's view the beat looks from
  # @param signal [Hash, nil] what the posted signal reads
  # @param metered [Boolean] whether the beat reads the machine from the meter the door hands in
  # @return [Hecks::Adapters::Dispatching::SignalboxDoor]
  def door(view: Hecks::Adapters::ReplayedLooking::MAIN, signal: nil, metered: false)
    @stand_ins = { "Looking"         => looking(view, metered: metered),
                   "PressurePosting" => Hecks::Adapters::ReplayedPressurePosting.new }
    runtime = boot_hecks_in_memory(Hecks::Adapters::Dispatching::SignalboxDoor::HOME)
    Hecks::Adapters::Dispatching::SignalboxDoor.new(runtime, signal: -> { signal })
  end

  # @yield the block run with the door's ports stood in
  def wired(&) = Hecks::Runtime::AdapterLookup.standing_in(->(port, _) { @stand_ins.fetch(port.to_s) }, &)

  # @param level [Integer] the reaction depth the caller stands at
  # @yield the block run at that depth
  def at_depth(level)
    key = Hecks::Adapters::Dispatching::OwnCascade::DEPTH
    Thread.current[key] = level
    yield
  ensure
    Thread.current[key] = nil
  end

  private

  # A look at the quiet machine, or, `metered`, at whatever meter the door hands in.
  def looking(view, metered: false)
    replayed = Hecks::Adapters::ReplayedLooking
    machine = metered ? {} : { machine: -> { replayed::QUIET } }
    Hecks::Adapters::Looking.new(settings: { view: -> { view }, **machine, delegate: -> { replayed::STARTED },
                                             marks: -> { Hecks::Adapters::Looking::Marks.new(nil).facts } })
  end
end
