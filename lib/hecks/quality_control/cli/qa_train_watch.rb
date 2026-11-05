# frozen_string_literal: true

require_relative "../../../hecks"

module Hecks
  module QualityControlCli
    # The command behind the QA tick's train watch: boots the Hecks domain and asks each queued
    # boarding's pull request whether it has merged (`Watch`). A merged one records its push, which
    # refreshes the launcher and announces the deploy; an open one changes nothing. The boardings
    # are read from the store the push train and the tick share (a copy opts in with local files).
    class QaTrainWatch
      EXIT_OK = 0
      EXIT_ERROR = 1

      USAGE = "usage: hecks quality_control train.watch!"

      # The first line of an error message.
      FIRST_LINE = /[^\n]*/

      # @param argv [Array<String>] no arguments
      # @param root [String] the repository root whose Hecks domain is watched
      # @return [Integer] 0 when every queued boarding was asked, 1 when one could not be
      # @raise [SystemExit] when given arguments
      def self.call(argv, root:)
        return reject(argv) unless argv.empty?

        new(root: root).run
      end

      # @param argv [Array<String>] the arguments given
      # @return [Integer] 0 for `--help`
      # @raise [SystemExit] for any other argument
      def self.reject(argv)
        return puts(USAGE) && EXIT_OK if %w[-h --help].include?(argv.first)

        abort "#{USAGE}\nthis command takes no arguments — every queued boarding is watched the same way"
      end

      # @param root [String] the repository root
      def initialize(root:)
        @root = root
      end

      # Asks every queued boarding its pull request's state.
      #
      # @return [Integer] 0, or 1 when a boarding could not be asked
      def run
        runtime = Hecks.boot(File.join(@root, "lib", "hecks", "hecks"), install_driving: false)
        queued = runtime.query("Hecks::SendTrain.Queued")
        return report(queued.size, 0) if queued.empty?

        failures = queued.count { |row| !watch(runtime, row) }
        report(queued.size, failures)
      end

      private

      # @return [Boolean] whether the boarding was asked without error
      def watch(runtime, row)
        run = row[:run][:value]
        runtime.dispatch_flat("Hecks::SendTrain.Watch", run: { value: run })
        puts "watched #{run}"
        true
      rescue StandardError => e
        puts "could not watch #{row[:run].inspect[0, 80]}: #{e.class}: #{first_line(e.message)}"
        false
      end

      def first_line(message)
        message[FIRST_LINE].to_s.strip
      end

      def report(queued, failures)
        puts "train watch: #{queued} queued boarding(s), #{failures} could not be asked"
        failures.zero? ? EXIT_OK : EXIT_ERROR
      end
    end
  end
end
