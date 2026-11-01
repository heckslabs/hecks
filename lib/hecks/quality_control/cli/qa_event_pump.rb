# frozen_string_literal: true

require_relative "../../../hecks"
# The era subsystem does not load with core (ADR 0033); the QualityControl ledger binds it.
require_relative "../../ports/persistence/plugins/era"
require_relative "qa_event_pump/attached"
require_relative "qa_event_pump/cursors"
require_relative "qa_event_pump/reader"
require_relative "qa_event_pump/consumer"

module Hecks
  module QualityControlCli
    # The command behind `hecks quality_control event_pump.pump!`: reads each attached domain's
    # event
    # log past its cursor and runs the policies that react to what it reads. A consumer reads the
    # logs of the domains its hecksagon subscribes to, and each cursor is one (log, consumer) row of
    # the ledger's `EventCursor`. The pump writes no domain's event log; the policies it runs write
    # their own commands' events, as any reaction does.
    #
    # A reaction that is refused is recorded and named in the output, and the cursor moves past its
    # event, so one bad event cannot hold the queue. A cursor is not moved for an event whose
    # reaction the pump could not run at all: that consumer stops, and the pump exits 1.
    class QaEventPump
      EXIT_OK = 0
      EXIT_ERROR = 1

      USAGE = "usage: hecks quality_control event_pump.pump!"

      # Runs the pump, or prints its usage for `--help`.
      #
      # @param argv [Array<String>] no arguments
      # @param root [String] the repository root the attached domains are found under
      # @param env [Hash{String => String}] `QA_SWEEP_DOMAIN_DIR` picks the ledger's bluebook
      #   directory
      # @return [Integer] 0 when every consumer read its logs, 1 when one could not
      # @raise [SystemExit] when given arguments
      def self.call(argv, root:, env: ENV)
        return reject(argv) unless argv.empty?

        new(root: root, env: env).run
      end

      # @param argv [Array<String>] the arguments given
      # @return [Integer] 0 for `--help`
      # @raise [SystemExit] for any other argument
      def self.reject(argv)
        return puts(USAGE) && EXIT_OK if %w[-h --help].include?(argv.first)

        abort "#{USAGE}\nthis command takes no arguments — one pump is always the same pump"
      end

      # @param root [String] the repository root
      # @param env [Hash{String => String}] the environment the ledger's directory is read from
      # @param attached [Attached, nil] the attached domains; built from `root` and `env` when
      #   absent
      def initialize(root:, env: ENV, attached: nil)
        @attached = attached || Attached.new(root: root, env: env)
      end

      # Runs every consumer once and prints what each reaction did.
      #
      # @return [Integer] 0 or 1, as `call` answers
      def run
        cursors = Cursors.new(@attached.runtime("QualityControl"))
        consumers = @attached.names.map { |name| Consumer.new(name, attached: @attached, cursors: cursors) }
        lines = consumers.flat_map(&:lines)
        lines.each { |line| puts line }
        puts "event pump: #{lines.size} line(s) reported"
        consumers.any?(&:failed?) ? EXIT_ERROR : EXIT_OK
      end
    end
  end
end
