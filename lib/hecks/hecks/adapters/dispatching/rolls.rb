# frozen_string_literal: true

require_relative "../console_capture"
require_relative "checkout"
require_relative "filling"
require_relative "last_roll"
require_relative "pending"
require_relative "planned_cache"
require_relative "quiet_beat"
require_relative "wake"

module Hecks
  module Adapters
    class Dispatching
      # The two questions an event or a beat of the clock puts to the queue: fill it now, and
      # has the clock alone made something eligible. They read the same work items, machine and
      # filling as the rest of {Dispatching}, which includes this module.
      module Rolls
        # Fills the queue because capacity freed or work arrived, unless the owner paused rolling.
        # A report that repeats the last one is refused, so a repeated skip is recorded once.
        #
        # @param _held [Hash] the `Roll` record
        # @return [Hash{Symbol => Hash}] `report:` the filling's report, and `held_back:` one when
        #   the filling left planned work waiting on the boot budget, the load or a pause, else zero
        # @raise [ConsoleCapture::Failure] when rolling is paused or the report repeats the last one
        def roll(**_held)
          raise ConsoleCapture::Failure, "paused: dispatch_roll_forward is false" unless machine.roll_forward?

          refuse_nested_roll!
          text = rolling_fill
          raise ConsoleCapture::Failure, "unchanged: #{header_of(text)}" if LastRoll.repeat?(text)

          { report: { value: text }, held_back: { value: held_back } }
        end

        # Says whether the clock alone has made something eligible to start: a retry time passed,
        # the boot budget freed, a roll was refused while a filling ran, or a slot is free that a
        # filling would use. A beat that finds none of these is refused as quiet and starts nothing;
        # when Signalbox's admission held the free slot, the refusal names the given ({QuietBeat}).
        #
        # @param held [Hash] the `Wake` record: `run`, the beat's key
        # @return [Hash{Symbol => Hash}] `roll:` the key of the roll to start, and `reason:`
        # @raise [ConsoleCapture::Failure] when rolling is paused, or nothing has become eligible
        def notice(**held)
          raise ConsoleCapture::Failure, "paused: dispatch_roll_forward is false" unless machine.roll_forward?

          admission = []
          reason = Wake.reason(beat_items, now: clock, **beat_questions(admission))
          raise ConsoleCapture::Failure, QuietBeat.message(admission.first) unless reason

          { roll: { value: "due-#{plain(held[:run])}" }, reason: { value: reason } }
        end

        private

        def clock = @standins[:now]&.call || Time.now.utc

        def header_of(report) = report.partition("\n").first

        # One when the filling just made left work waiting on the boot budget or on the machine.
        # It reads what {#note_stops} wrote in this process, so it holds only after a
        # confirmed filling.
        def held_back = Pending.budget_stopped || Pending.load_stopped ? 1 : 0

        # What a confirmed filling leaves for the clock's beat: whether the boot budget stopped it,
        # and when the window alone could free the budget; and whether the machine held planned work
        # back. Only a confirmed filling writes this, so a dry plan between a stop and the next beat
        # cannot clear it.
        def note_stops(plan)
          stopped = !plan.budget_stop.nil?
          Pending.budget_stopped = stopped
          Pending.budget_frees_at = stopped ? machine.boot_frees_at : nil
          Pending.load_stopped = plan.held_by_machine?
        end

        # The planned items, as the last beat or confirmed filling read them a short while ago.
        def beat_items
          key = [@registry.object_id, @standins[:work_items].object_id]
          PlannedCache.items(key, clock) { work_items.rollable }
        end

        # What the beat asks of the machine, each asked only once its flag says it could matter.
        # `held` collects why admission left the free slot unused, for this beat's refusal alone.
        def beat_questions(held)
          { stopped: -> { fuse_stop }, frees_at: -> { machine.boot_frees_at }, cleared: -> { machine_clear? },
            room: -> { free_starts(held) } }
        end

        # How many planned items a rolling filling would start now, planned from the items the beat
        # keeps. The plan is made only when no filling runs in this process and something is
        # planned; the plan itself holds every item back on load or a pause. A full cap answers
        # nought before any plan, unless Signalbox admits by headroom, where the plan asks
        # admission in place of the cap, and the reason admission held an item goes into `held`.
        def free_starts(held = [])
          return 0 if Filling.running? || (items = beat_items).empty?

          started = work_items.started
          return 0 if !admitting && started.size >= machine.cap

          QuietBeat.starts(Plan.new(items, started, **limits), held)
        end

        # Whether the load is back under its limit and no crossing pauses the starts.
        def machine_clear?
          gauge = machine
          gauge.paused.nil? && gauge.load <= gauge.max_load
        end

        # A roll that begins while a filling runs would start the same work twice, so it is
        # refused; the refusal is remembered so the filling that is running rolls again once done.
        def refuse_nested_roll!
          return unless Filling.running?

          Pending.defer!
          raise ConsoleCapture::Failure, "unchanged: a filling is already running; this roll runs again when it ends"
        end

        # The report of a rolling filling. A roll refused while it ran freed capacity this filling's
        # plan did not see, so it fills once more.
        def rolling_fill
          text = confirmed_report
          Pending.take_deferred! ? confirmed_report : text
        end

        # The filling is for the main checkout, whichever worktree's process heard the roll: a
        # session started in a worktree would be handed that work item's directory.
        def confirmed_report
          choose(repo: { value: Checkout.main(Dir.pwd) }, confirm: true, rolling: true).dig(:report, :value)
        end
      end
    end
  end
end
