# frozen_string_literal: true

require_relative "console_capture"
require_relative "dispatching/settings"
require_relative "dispatching/work_items"
require_relative "dispatching/plan"
require_relative "dispatching/launcher"
require_relative "dispatching/lesson_traps"
require_relative "dispatching/settler"
require_relative "dispatching/last_roll"

module Hecks
  module Adapters
    # The `Dispatching` port's adapter for `Dispatch`: reads the Work queue and the machine, says
    # which
    # planned work items would start a session and why each other waits, and with `confirm` starts
    # them.
    #
    # It decides only what the Plan rules decide; whether a work item may start is still the
    # bluebook's
    # (the `WorkAreas` and `WorkLimits` ports refuse a start that clashes or goes over the cap). The
    # default is a dry run, which writes nothing.
    class Dispatching
      # @param registry [Runtime::Registry, nil] the booted registry whose work items are read
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `load:`, `cpus:` and `runner:` stand in for the machine and the
      #   launcher
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @registry = registry
        @standins = settings
      end

      # Says which planned work items start now, and starts them when confirmed.
      #
      # @param held [Hash] the `Dispatch` record: `repo`, `budget_minutes`, `confirm`, and `only`,
      #   the key prefix the choice is held to
      # @return [Hash{Symbol => Hash}] `report:` the load; one line for each chosen work item, which
      #   says it would start or, when confirmed, that it started or why it went back to the plan;
      #   then the work items left waiting with the reason
      def choose(**held)
        confirmed = plain(held[:confirm]) == true
        settle_ended(held) if confirmed
        { report: { value: filling_lines(plan_for(prefix(held)), held, confirmed).join("\n") } }
      end

      # Says which planned work items would start now and why each other waits, without starting
      # any of them. It reads the same plan `choose` reads, so it never writes and never launches.
      #
      # @param held [Hash] the query's `repo`, `budget_minutes` and `only` (the key prefix)
      # @return [Hash{Symbol => String}] `text:` the report, one line per work item
      def preview(**held)
        { text: "#{report_lines(plan_for(prefix(held))).join("\n")}\n" }
      end

      # Fills the queue because capacity freed or work arrived, unless the owner paused rolling.
      # A report that repeats the last one is refused, so a repeated skip is recorded once.
      #
      # @param _held [Hash] the `Roll` record
      # @return [Hash{Symbol => Hash}] `report:` the filling's report
      # @raise [ConsoleCapture::Failure] when rolling is paused or the report repeats the last one
      def roll(**_held)
        raise ConsoleCapture::Failure, "paused: dispatch_roll_forward is false" unless machine.roll_forward?

        text = choose(repo: { value: Dir.pwd }, confirm: true).dig(:report, :value)
        raise ConsoleCapture::Failure, "unchanged: #{header_of(text)}" if LastRoll.repeat?(text)

        { report: { value: text } }
      end

      # Checks every started session and settles the work item of each that ended: done finishes it.
      #
      # @param held [Hash] the `Dispatch` record: `repo`
      # @return [Hash{Symbol => Hash}] `report:` one line per work item settled
      def conclude(**held)
        lines = Settler.new(work_items, launcher_for(held)).call
        { report: { value: lines.empty? ? "nothing to settle" : lines.join("\n") } }
      end

      private

      # The load, each work item that starts or would, then each left waiting with its reason.
      def filling_lines(plan, held, confirmed)
        chosen = confirmed ? launch(plan, held) : plan.chosen.map { |item| chosen_line(item) }
        [header(plan)] + chosen + plan.skipped.map { |skip| skipped_line(skip) }
      end

      # A confirmed filling finishes or yields the work items whose sessions ended before the plan
      # counts started rows, so the cap holds only live work.
      def settle_ended(held) = Settler.new(work_items, launcher_for(held)).call

      def work_items = @standins[:work_items] || WorkItems.new(@registry)

      def machine = Settings.new(@registry, load: @standins[:load], cpus: @standins[:cpus], cap: @standins[:cap])

      def launcher_for(held) = Launcher.new(plain(held[:repo]), runner: @standins[:runner])

      def plan_for(only = "")
        Plan.new(planned(only), work_items.started, cap: machine.cap, load: machine.load, max_load: machine.max_load,
                                                    frozen: machine.frozen)
      end

      # The key prefix a filling is held to; empty when none is named.
      def prefix(held) = plain(held[:only]).to_s

      # The load, then each work item that starts or would, then each left waiting with its reason.
      def report_lines(plan)
        [header(plan)] + plan.chosen.map { |item| chosen_line(item) } + plan.skipped.map { |skip| skipped_line(skip) }
      end

      # The planned work items, held to those whose key starts with `only` when one is named.
      def planned(only) = work_items.planned.select { |item| only.empty? || item.key.to_s.start_with?(only) }

      def header_of(report) = report.partition("\n").first

      def header(plan)
        "#{load_line}; started #{work_items.started.size} of cap #{machine.cap}; " \
          "this fill would start #{plan.chosen.size}; frozen: #{frozen_line}"
      end

      def load_line = "load #{machine.load.round(1)} (limit #{machine.max_load.round(1)}, #{machine.cpus} cpus)"

      def frozen_line = machine.frozen.empty? ? "none" : machine.frozen.join(", ")

      def chosen_line(item) = "would start #{item.key}: #{BriefText.new("outcome" => item.title).first_line}"

      def skipped_line(skip) = "#{skip.key} #{skip.reason}"

      def launch(plan, held)
        launcher = launcher_for(held)
        minutes = plain(held[:budget_minutes]) || Settings::BUDGET_MINUTES
        plan.chosen.each_with_index.map do |item, index|
          launched(launcher, item) do
            launcher.launch(item, held: holding(plan, index), minutes: minutes, limit: machine.spec_files_limit,
                                  frozen: machine.frozen, traps: traps_for(item))
          end
        end
      end

      # One work item's launch line. An error the launcher did not expect yields that work item
      # with the error's class and message, so the next chosen work item still launches and the
      # report still says why; a yield that fails too is named on the line.
      def launched(launcher, item)
        yield
      rescue StandardError => e
        reason = "#{e.class}: #{e.message}"
        begin
          launcher.yield_back(item, reason)
        rescue StandardError => failure
          "#{item.key} could not be started or yielded: #{reason} (yield failed: #{failure.class}: #{failure.message})"
        end
      end

      # The known traps the work item's area meets, one line each.
      def traps_for(item) = LessonTraps.new(work_items.lessons).for(item.area)

      # A line for each other work item, started or chosen before this one, that holds an area.
      def holding(plan, index)
        (work_items.started + plan.chosen.first(index)).reject { |other| other.area.empty? }.map { |other| held_line(other) }
      end

      def held_line(item) = "#{item.key}: #{item.title} (#{item.area.join(", ")})"

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
