# frozen_string_literal: true

require_relative "console_capture"
require_relative "dispatching/settings"
require_relative "dispatching/rows"
require_relative "dispatching/plan"
require_relative "dispatching/launcher"
require_relative "dispatching/settler"

module Hecks
  module Adapters
    # The `Dispatching` port's adapter for `Dispatch`: reads the Work queue and the machine, says which
    # planned rows would start a session and why each other waits, and with `confirm` starts them.
    #
    # It decides only what the Plan rules decide; whether a row may start is still the bluebook's
    # (the `WorkAreas` and `WorkLimits` ports refuse a start that clashes or goes over the cap). The
    # default is a dry run, which writes nothing.
    class Dispatching
      # @param registry [Runtime::Registry, nil] the booted registry whose rows are read
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `load:`, `cpus:` and `runner:` stand in for the machine and the launcher
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @registry = registry
        @standins = settings
      end

      # Says which planned rows start now, and starts them when confirmed.
      #
      # @param held [Hash] the `Dispatch` record: `repo`, `budget_minutes`, `confirm`
      # @return [Hash{Symbol => Hash}] `report:` the load, the rows started or that would be, and the
      #   rows left waiting with the reason
      def choose(**held)
        plan = plan_for
        lines = [header(plan)] + plan.chosen.map { |row| chosen_line(row) } + plan.skipped.map { |skip| skipped_line(skip) }
        lines += launch(plan, held) if plain(held[:confirm]) == true
        { report: { value: lines.join("\n") } }
      end

      # Checks every started session and settles the row of each that ended: done finishes it.
      #
      # @param held [Hash] the `Dispatch` record: `repo`
      # @return [Hash{Symbol => Hash}] `report:` one line per row settled
      def conclude(**held)
        lines = Settler.new(rows, launcher_for(held)).call
        { report: { value: lines.empty? ? "nothing to settle" : lines.join("\n") } }
      end

      private

      def rows = @standins[:rows] || Rows.new(@registry)

      def machine = Settings.new(@registry, load: @standins[:load], cpus: @standins[:cpus])

      def launcher_for(held) = Launcher.new(plain(held[:repo]), runner: @standins[:runner])

      def plan_for
        Plan.new(rows.planned, rows.started, cap: machine.cap, load: machine.load, max_load: machine.max_load,
                                             frozen: machine.frozen)
      end

      def header(plan)
        "#{load_line}; cap #{machine.cap}, #{rows.started.size} started; frozen: #{frozen_line}; #{plan.chosen.size} to start"
      end

      def load_line = "load #{machine.load.round(1)} (limit #{machine.max_load.round(1)}, #{machine.cpus} cpus)"

      def frozen_line = machine.frozen.empty? ? "none" : machine.frozen.join(", ")

      def chosen_line(row) = "would start #{row.key}: #{BriefText.new("outcome" => row.title).first_line}"

      def skipped_line(skip) = "#{skip.key} #{skip.reason}"

      def launch(plan, held)
        launcher = launcher_for(held)
        minutes = plain(held[:budget_minutes]) || Settings::BUDGET_MINUTES
        plan.chosen.each_with_index.map do |row, index|
          launcher.launch(row, held: holding(plan, index), frozen: machine.frozen, minutes: minutes,
                          limit: machine.spec_files_limit)
        end
      end

      # A line for each other row, started or chosen before this one, that holds an area.
      def holding(plan, index)
        (rows.started + plan.chosen.first(index)).reject { |other| other.area.empty? }.map { |other| held_line(other) }
      end

      def held_line(row) = "#{row.key}: #{row.title} (#{row.area.join(", ")})"

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
