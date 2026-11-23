# frozen_string_literal: true

require "hecks"
require "hecks/adapters/driving/clock"

module Hecks
  module Adapters
    # The `ClockRunning` port's adapter: boots a domain directory in this process and runs one of
    # its clocks until it is stopped, or answers when each clock next fires and the process files
    # that run them. A raise records a refusal.
    class ClockRunning
      # @param registry [Runtime::Registry, nil] unused
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil); end

      # The `RunClock` ask: runs the record's clock, logging each firing on stderr.
      #
      # @param held [Hash] the `Clock` record: `domain`, `clock` and an optional `ticks`
      # @return [Hash{Symbol => Hash}] `output:` how many ticks fired
      # @raise [Runtime::NotFound] if the domain or clock cannot be found
      def run_clock(**held)
        name = plain(held[:clock])
        runner = Driving::Clock.runner(boot(held[:domain]), name)
        fired = runner.run(ticks: plain(held[:ticks]))
        { output: { value: "clock #{name} stopped after #{fired} firing(s)" } }
      end

      # The `Next` query.
      #
      # @param domain [Hash, String] a domain directory
      # @return [Hash] `text:` one line per clock with its next fire time
      def next(domain:)
        { text: Driving::Clock.upcoming(boot(domain), Driving::Clock::SystemTime.now) }
      end

      # The `LaunchFiles` query.
      #
      # @param domain [Hash, String] a domain directory
      # @return [Hash] `text:` the Procfile lines, then a property list per clock
      def launch_files(domain:)
        directory = File.expand_path(plain(domain))
        names = Driving::Clock.declared(boot(domain)).map { |_, clock| clock.name }
        files = Driving::Clock::LaunchFiles
        plists = names.map { |name| "# #{files.label(directory, name)}.plist\n#{files.plist(directory, name)}" }
        { text: ["# Procfile", files.procfile(directory, names), *plists].join("\n") }
      end

      private

      def boot(domain)
        path = plain(domain)
        raise Runtime::NotFound, "no such domain #{path.inspect}" unless path && Dir.exist?(path)

        runtime = Hecks.boot(File.expand_path(path), install_driving: false)
        Assembly.bind_ported_runtime(runtime)
        runtime
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
