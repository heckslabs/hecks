# frozen_string_literal: true

require "open3"
require "hecks/runtime/errors"

module Hecks
  module Adapters
    # The `Machine` port's adapter for the Onboarding bluebook: it reads the machine it runs on.
    # Each method answers one ask of the port with the reading the answer event carries, and
    # refuses with a message that names the next thing to do when the machine cannot answer.
    class MachineProbe
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # Reads the Ruby on the machine's path.
      #
      # @param machine [Hash, String] the machine being onboarded
      # @param _held [Hash] the rest of the record the runtime passes along; unused
      # @return [Hash] `machine:`, `major:` and `minor:` of the `ruby` found
      # @raise [Runtime::GivenNotMet] when no `ruby` runs or its version cannot be read
      def read_ruby_version(machine:, **_held)
        out, = run("ruby", "-e", "print RUBY_VERSION")
        major, minor = out.split(".").first(2).map { |part| Integer(part, exception: false) }
        raise Runtime::GivenNotMet, "ruby answered #{out.inspect}, not a version" unless major && minor

        { machine: plain(machine), major: major, minor: minor }
      end

      # Asks RubyGems whether the hecks gem is installed.
      #
      # @param machine [Hash, String] the machine being onboarded
      # @param _held [Hash] the rest of the record the runtime passes along; unused
      # @return [Hash] `machine:` and `exit_code:` 0
      # @raise [Runtime::GivenNotMet] when `gem` cannot run or the gem is not installed
      def find_hecks_gem(machine:, **_held)
        _out, status = run("gem", "list", "--installed", "hecks")
        raise Runtime::GivenNotMet, "the hecks gem is not installed; run: gem install hecks" unless status.success?

        { machine: plain(machine), exit_code: status.exitstatus }
      end

      # Runs the `hecks` launcher with no arguments, which lists its commands.
      #
      # @param machine [Hash, String] the machine being onboarded
      # @param _held [Hash] the rest of the record the runtime passes along; unused
      # @return [Hash] `machine:` and `exit_code:` 0
      # @raise [Runtime::GivenNotMet] when `hecks` is not on the path or exits non-zero
      def list_launcher_commands(machine:, **_held)
        out, status = run("hecks")
        unless status.success?
          raise Runtime::GivenNotMet, "hecks exited #{status.exitstatus} (0 answered, 1 refused, 2 unreadable)"
        end
        raise Runtime::GivenNotMet, "hecks answered nothing" if out.strip.empty?

        { machine: plain(machine), exit_code: status.exitstatus }
      end

      private

      # A value object arrives as `{value: x}`; a plain argument arrives as itself.
      def plain(held) = held.is_a?(Hash) ? held.values.first : held

      def run(*command)
        out, status = Open3.capture2e(*command)
        [out, status]
      rescue SystemCallError => e
        raise Runtime::GivenNotMet, "cannot run #{command.first}: #{e.message}"
      end
    end
  end
end
