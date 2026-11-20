# frozen_string_literal: true

require_relative "../../../hecks"
# The era subsystem does not load with core (ADR 0033); the QualityControl ledger binds it.
require_relative "../../ports/persistence/plugins/era"
require_relative "../../adapters/driven/event_pump"
require_relative "qa_event_pump/attached"

module Hecks
  module QualityControlCli
    # The QA ledger's run of EventDelivery's pump (`Adapters::EventPump`, ADR 0178), behind the
    # `PumpTools` adapter and the QA tick: the domains QualityControl attaches are the consumers,
    # and the QualityControl ledger, which attaches EventDelivery, holds their cursors and
    # reactions. It prints each line the pump reports, and exits 1 when a consumer stopped.
    class QaEventPump
      EXIT_OK = 0
      EXIT_ERROR = 1

      USAGE = "usage: qa_event_pump (the QA ledger's EventDelivery Pump.Run)"

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
        report = Adapters::EventPump.new(attached: @attached, ledger: "QualityControl").run
        report[:lines].each { |line| puts line }
        puts "event pump: #{report[:lines].size} line(s) reported"
        report[:failed] ? EXIT_ERROR : EXIT_OK
      end
    end
  end
end
