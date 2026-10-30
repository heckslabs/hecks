# frozen_string_literal: true

require_relative "../../../hecks"
# The era subsystem does not load with core; the `PostgresEra` binding needs it (ADR 0033).
require_relative "../../ports/persistence/plugins/era"
require_relative "qa_log_bug/arguments"
require_relative "qa_log_bug/proof"

module Hecks
  module QualityControlCli
    # The command behind `hecks quality_control bug.log`: logs a bug to the QualityControl ledger,
    # proven, numbered and triaged. It runs `--demonstration` first and refuses unless it exits
    # non-zero.
    #
    #   hecks quality_control bug.log --sweep <sweep-id> --title "…" \
    #     --demonstration "bundle exec rspec spec/x_spec.rb -e 'the case'" \
    #     --symptom "…" --expectation "…" --submitter "<who>" \
    #     --triage self_contained|bigger [--tag word]… [--reproduced yes|no]
    #
    # `--reproduced no` skips the run for findings that will not reproduce reliably; the
    # demonstration must still look like runnable code, not prose. Exit 0: logged, with
    # `logged BUG#n …` as the last stdout line. Exit 1: refused, nothing written.
    class QaLogBug
      include Arguments
      include Proof

      EXIT_OK = 0

      USAGE = "usage: hecks quality_control log --sweep <sweep-id> --title \"…\" " \
              "--demonstration \"<command that must FAIL>\" --symptom \"…\" --expectation \"…\" " \
              "--submitter \"<who>\" --triage self_contained|bigger [--tag word]… [--reproduced yes|no]"

      DISPOSITIONS = %w[self_contained bigger].freeze
      REPRODUCED = %w[yes no].freeze
      VALUE_FLAGS = %w[--sweep --title --demonstration --symptom --expectation --submitter --triage
                       --reproduced].freeze

      # Logs the bug.
      #
      # @param argv [Array<String>] the flags in the usage line
      # @param root [String] the repository root, where the demonstration runs
      # @param env [Hash{String => String}] `QA_SWEEP_DOMAIN_DIR` points at another ledger
      # @return [Integer] 0 once logged
      # @raise [SystemExit] when the arguments are wrong or a rule refuses; nothing is written
      def self.call(argv, root:, env: ENV)
        new(root: root, env: env).call(argv)
      end

      # @param root [String] the repository root
      # @param env [Hash{String => String}] `QA_SWEEP_DOMAIN_DIR` points at another ledger
      def initialize(root:, env: ENV)
        @root = root
        @domain_dir = env.fetch("QA_SWEEP_DOMAIN_DIR", File.join(root, "qa/bluebook"))
      end

      # @param argv [Array<String>] the flags in the usage line
      # @return [Integer] the exit status
      # @raise [SystemExit] when the arguments are wrong or a rule refuses; nothing is written
      def call(argv)
        options = parse(argv.dup)
        return EXIT_OK if options == :help

        validate(options)
        prove(options)
        puts
        sweep, bug = log_bug(options)
        puts logged_line(bug, sweep, options)
        EXIT_OK
      end

      private

      def log_bug(options)
        runtime = boot_ledger
        sweep = find_sweep(options[:sweep])
        [sweep, mint_and_log!(runtime, sweep, options).triage!(disposition: { value: options[:triage] })]
      end

      def find_sweep(id)
        ::QualityControl::Sweep.find(id) ||
          abort("no such sweep: #{id.inspect} — the sweep id is on hecks quality_control ask run's own " \
                "FOUND SOMETHING report")
      end

      def logged_line(bug, sweep, options)
        "logged #{bug.id} (sequence #{bug.sequence.value}, #{bug.disposition.value}, " \
          "reproduced=#{bug.reproduced.value}) against #{sweep.id}: #{options[:title]}"
      end

      def boot_ledger
        Hecks.boot(@domain_dir)
      rescue StandardError => e
        abort "the QualityControl ledger did not boot — fix the ledger itself before logging against it " \
              "(#{e.class}: #{e.message})"
      end

      # Re-read on every attempt: concurrent minters see the same maximum, and the loser's `Log` is
      # refused (`AlreadyExists`) so `mint_and_log!` retries from a fresh read.
      def next_reference(runtime)
        rows = runtime.query("QualityControl::Bug.All")
        taken = rows.map { |row| row[:reference][:value] }
        sequence = rows.map { |row| row[:sequence][:value] }.max.to_i + 1
        sequence += 1 while taken.include?("BUG##{sequence}")
        [sequence, "BUG##{sequence}"]
      end

      # Retries up to three times: the reference can be taken between reading and logging.
      def mint_and_log!(runtime, sweep, options)
        3.times do
          sequence, reference = next_reference(runtime)
          begin
            return log(sweep, options, sequence, reference)
          rescue Hecks::Runtime::AlreadyExists
            puts "#{reference} was taken between reading Bug.All and logging — minting again"
          end
        end
        abort "could not mint a free BUG# reference in three attempts — another minter is racing this one; " \
              "run again"
      end

      def log(sweep, options, sequence, reference)
        tags = options[:tags].empty? ? {} : { tags: options[:tags].map { |tag| { value: tag } } }
        ::QualityControl::Bug.log!(
          sweep: sweep.id, reference: { value: reference }, sequence: { value: sequence },
          title: { value: options[:title] }, demonstration: { value: options[:demonstration] },
          symptom: { value: options[:symptom] }, expectation: { value: options[:expectation] },
          submitter: { value: options[:submitter] }, reproduced: { value: options[:reproduced] }, **tags
        )
      end
    end
  end
end
