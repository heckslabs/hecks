# frozen_string_literal: true

require_relative "console_capture"
require_relative "dispatching/settings"
require_relative "dispatching/work_items"
require_relative "dispatching/plan"
require_relative "dispatching/launcher"
require_relative "dispatching/lesson_traps"
require_relative "dispatching/settler"

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
      # @param held [Hash] the `Dispatch` record: `repo`, `budget_minutes`, `only`, `confirm`
      # @return [Hash{Symbol => Hash}] `report:` the load, the work items started or that would be,
      #   and
      #   the
      #   work items left waiting with the reason
      def choose(**held)
        plan = plan_for(plain(held[:only]))
        lines = report_lines(plan)
        lines += launch(plan, held) if plain(held[:confirm]) == true
        { report: { value: lines.join("\n") } }
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

      def work_items = @standins[:work_items] || WorkItems.new(@registry)

      def machine = Settings.new(@registry, load: @standins[:load], cpus: @standins[:cpus])

      def launcher_for(held) = Launcher.new(plain(held[:repo]), runner: @standins[:runner])

      def plan_for(only = nil)
        Plan.new(planned_with(only), work_items.started, cap: machine.cap, load: machine.load,
                                                         max_load: machine.max_load, frozen: machine.frozen)
      end

      # The planned work items whose id starts with `only`, or all of them when it is left out.
      def planned_with(only) = work_items.planned.select { |item| only.nil? || item.key.start_with?(only) }

      def report_lines(plan)
        [header(plan)] + plan.chosen.map { |item| chosen_line(item) } + plan.skipped.map { |skip| skipped_line(skip) }
      end

      def header(plan)
        "#{load_line}; cap #{machine.cap}, #{work_items.started.size} started; frozen: #{frozen_line}; " \
          "#{plan.chosen.size} to start"
      end

      def load_line = "load #{machine.load.round(1)} (limit #{machine.max_load.round(1)}, #{machine.cpus} cpus)"

      def frozen_line = machine.frozen.empty? ? "none" : machine.frozen.join(", ")

      def chosen_line(item) = "would start #{item.key}: #{BriefText.new("outcome" => item.title).first_line}"

      def skipped_line(skip) = "#{skip.key} #{skip.reason}"

      def launch(plan, held)
        launcher = launcher_for(held)
        minutes = plain(held[:budget_minutes]) || Settings::BUDGET_MINUTES
        plan.chosen.each_with_index.map do |item, index|
          launcher.launch(item, held: holding(plan, index), minutes: minutes, limit: machine.spec_files_limit,
                                frozen: machine.frozen, traps: traps_for(item))
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
