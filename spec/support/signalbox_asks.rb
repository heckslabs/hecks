# frozen_string_literal: true

require "support/signalbox_door_wiring"

# A Signalbox booted in Memory that a spec beats, records holds in and asks by declared query.
module SignalboxAsks
  include SignalboxDoorWiring

  # @return [#dispatch, #query] a Signalbox whose beat looks at the quiet machine from main
  def signalbox
    @signalbox ||= begin
      @stand_ins = { "Looking"         => looking(Hecks::Adapters::ReplayedLooking::MAIN),
                     "PressurePosting" => Hecks::Adapters::ReplayedPressurePosting.new }
      boot_hecks_in_memory(Hecks::Adapters::Dispatching::SignalboxDoor::HOME)
    end
  end

  # @param key [String] the beat begun, which looks at the quiet machine from main
  # @return [Object] what the dispatch answered
  def begin_beat(key) = wired { signalbox.dispatch("Signalbox::Beat.Begin", with: { beat: { value: key } }) }

  # @param name [String] a query as `Aggregate.Query`
  # @return [Array<Hash>] its rows
  def ask(name, **) = signalbox.query("Signalbox::#{name}", **)

  # @param key [String] the hold's own key
  # @param subject [String] the work item held
  # @param reason [String] why, in plain words
  # @param held_at [Integer] when, in epoch seconds
  # @return [Object] what the dispatch answered
  def hold(key, subject, reason, held_at)
    facts = { hold: key, subject: subject, reason: reason, decided_by: "signalbox", band: "short", now: held_at }
    signalbox.dispatch("Signalbox::Hold.Record", with: facts.transform_values { |fact| { value: fact } })
  end

  # @param row [Hash] a query's row
  # @param field [Symbol] one of its fields
  # @return [Object] the field's bare value
  def plain(row, field) = Hecks::Adapters::StartedWork.value(row, field)
end
