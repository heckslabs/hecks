# frozen_string_literal: true

require_relative "guarding/launch_agent"
require_relative "guarding/roster_rows"

module Hecks
  module Adapters
    # The `Guarding` port's adapter for `Watchdog`: puts the launchd job that keeps the pinned
    # sessions working in place, or takes it away. The job's loop (`Guarding::Loop`) runs apart
    # from Hecks and Claude and boots none of the domain; the roster it reads is the bluebook's
    # rows, written once here when the job is armed. Unconfirmed, each ask answers what it would do.
    class Guarding
      # @param registry [Runtime::Registry, nil] the booted registry whose roster rows are read
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `home:` and `runner:` stand in for the home directory and `launchctl`
      def initialize(registry: nil, aggregate: nil, settings: {})
        @registry = registry
        @home = settings[:home] || Dir.home
        @runner = settings[:runner]
      end

      # @param held [Hash] the `Watchdog` record: `confirm` lets the launch agents be written
      # @return [Hash{Symbol => Hash}] `report:` what was done, or would be
      # @raise [ConsoleCapture::Failure] when launchd refuses the job
      def guard(**held)
        roster = RosterRows.new(@registry, home: @home).json
        { report: { value: agent.install(roster: roster, confirm: plain(held[:confirm]) == true) } }
      end

      # @param held [Hash] the `Watchdog` record: `confirm` lets the launch agents be written
      # @return [Hash{Symbol => Hash}] `report:` what was done, or would be
      def release(**held) = { report: { value: agent.uninstall(confirm: plain(held[:confirm]) == true) } }

      private

      def agent = LaunchAgent.new(home: @home, runner: @runner)

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
