# frozen_string_literal: true

require_relative "plan"
require_relative "plan_admission"
require_relative "stop_reason"

module Hecks
  module Adapters
    class Dispatching
      # Why a fill that starts nothing is held, said for a `FillStalled` event: the dominant reason
      # among the plan's waits, the reading behind it, and the setting or switch that governs it.
      #
      # It only words what the plan and the machine already say; it decides nothing.
      class StallReading
        # The kinds a wait is counted under here, matched in order before {StopReason}'s own: the
        # machine's holds apart, so each names its own reading and governor.
        KINDS = {
          /\Askipped: load/ => "load", /paused by load/ => "load pause", /memory low/ => "memory",
          /boot/ => "boot budget", /\A#{Regexp.escape(PlanAdmission::ADMISSION)}/o => "signalbox admission"
        }.freeze

        # What governs each kind: the setting, switch or record that lifts it.
        GOVERNORS = {
          "owner pause"         => "dispatch_roll_forward in the Tickets world, or the open merge window (MergeWindow.close!)",
          "load"                => "dispatch_max_load in the Tickets world",
          "load pause"          => "machine_marks load_high in the Tickets world; it lifts at Machine.LoadFellBelow",
          "memory"              => "machine_marks in the Tickets world; it lifts at Machine.MemoryRecovered",
          "boot budget"         => "cpu_budget boot_hours_per_day in the Tickets world",
          "signalbox admission" => "admission.signalbox in the Tickets world and the Signalbox world's marks",
          "cap"                 => "the cap on started work in the Tickets world",
          "pause"               => "the pressure band Signalbox posted; it lifts when the band eases",
          "area overlap"        => "the areas the started work items hold (Work.rescope!, or their landing)",
          "frozen"              => "frozen_shapes in the Tickets world",
          "epic"                => "epic_wip_limit in the Tickets world",
          "parked"              => "each item's retry time or the run it is parked behind",
          "dependency"          => "the work items they wait on (Work.wait_on!)"
        }.freeze

        # What governs a wait no kind names.
        UNNAMED = "nothing named: read the reason and Dispatch.preview"

        # @param skipped [Array<#reason>] the plan's waiting work items
        # @param machine [Hash] `load:`, `source:`, `max_load:` and `load_high:` (the readings a
        #   load reason is said with), `rolling:` (false while the owner's pause stands) and
        #   `waiting:` (the rollable items that pause holds)
        def initialize(skipped, **machine)
          @skipped = skipped
          @machine = machine
        end

        # @return [Hash{Symbol => String}] `reason:`, `reading:` and `governed_by:`, each empty
        #   when nothing waits and no pause stands
        def to_h
          kind, count = dominant
          return { reason: "", reading: "", governed_by: "" } unless kind

          { reason: "#{count} held by #{kind}", reading: reading(kind), governed_by: GOVERNORS.fetch(kind, UNNAMED) }
        end

        private

        # The owner's pause holds every waiting item, whatever the plan says of each.
        def dominant
          return kinds.tally.max_by { |_kind, count| count } unless @machine[:rolling] == false

          ["owner pause", @machine[:waiting]] if @machine[:waiting].to_i.positive?
        end

        def kinds = @skipped.map { |skip| kind_of(skip.reason) }

        def kind_of(reason) = KINDS.find { |pattern, _| pattern.match?(reason) }&.last || StopReason.kind_of(reason)

        def reading(kind)
          case kind
          when "owner pause" then "dispatch_roll_forward is false, or a merge window is open"
          when "load"        then "#{load_from} against dispatch_max_load #{@machine[:max_load]}"
          when "load pause"  then "#{load_from} against load_high #{@machine[:load_high]}"
          else first_reason(kind)
          end
        end

        def load_from = "load #{@machine[:load].to_f.round(1)} from #{@machine[:source]}"

        # The first wait of the kind, as the plan words it.
        def first_reason(kind)
          @skipped.find { |skip| kind_of(skip.reason) == kind }.reason.delete_prefix("skipped: ")
        end
      end
    end
  end
end
