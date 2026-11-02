# frozen_string_literal: true

require "open3"
require_relative "../../../hecks"
# The era subsystem does not load with core (ADR 0033); the QualityControl ledger binds it.
require_relative "../../ports/persistence/plugins/era"
require_relative "qa_main_gate/gate_run"
require_relative "qa_main_gate/worktree"
require_relative "qa_main_gate/shell"
require_relative "qa_main_gate/sweeping"
require_relative "qa_main_gate/logging"
require_relative "qa_fix_main_bug"

module Hecks
  module QualityControlCli
    # The command behind `hecks quality_control main_check.check_main`, the tick's main-check step. It runs
    # the quick gate on local main in a temporary worktree, records the verdict against the commit, and
    # for each red check logs one bug proven by its output. A self-contained bug is handed to
    # `QaFixMainBug`. A commit already on record is answered from the record, so a tick that finds it again
    # logs nothing twice.
    #
    # Exit 0 when main is green, 2 when a check is red (the bugs are on the ledger), 1 on an operational
    # error. `QA_SWEEP_DOMAIN_DIR` picks the ledger, as for the other QA commands.
    class QaMainGate
      include Sweeping
      include Logging

      EXIT_OK = 0
      EXIT_ERROR = 1
      EXIT_FOUND_SOMETHING = 2

      USAGE = "usage: hecks quality_control main_check.check_main"

      # Runs the step.
      #
      # @param argv [Array<String>] no arguments
      # @param root [String] the repository root, whose local `main` is checked
      # @param env [Hash{String => String}] `QA_SWEEP_DOMAIN_DIR` picks another ledger
      # @param gate [#run] runs the quick gate in a directory and answers its results; a spec injects one
      # @param shell [Module] the fixer, landing and push commands; a spec injects one
      # @return [Integer] the exit status
      def self.call(argv, root:, env: ENV, gate: GateRun, shell: Shell)
        new(root: root, env: env, gate: gate, shell: shell).call(argv)
      end

      # @param root [String] the repository root
      # @param env [Hash{String => String}] `QA_SWEEP_DOMAIN_DIR` picks another ledger
      # @param gate [#run] the quick gate's runner
      # @param shell [Module] the fixer, landing and push commands
      def initialize(root:, env: ENV, gate: GateRun, shell: Shell)
        @root = root
        @domain_dir = env.fetch("QA_SWEEP_DOMAIN_DIR", File.join(root, "qa/bluebook"))
        @gate = gate
        @shell = shell
      end

      # @param argv [Array<String>] no arguments
      # @return [Integer] the exit status
      def call(argv)
        return reject(argv) unless argv.empty?

        @runtime = boot_ledger
        sha = Worktree.git!(@root, "rev-parse", "--verify", "main")
        recorded = recorded_verdict(sha)
        return answer_recorded(sha, recorded) if recorded

        results = Worktree.with(root: @root, ref: sha) { |dir| @gate.run(dir) }
        judge(sha, results)
      end

      private

      def reject(argv)
        return puts(USAGE) && EXIT_OK if %w[-h --help].include?(argv.first)

        warn "#{USAGE}\nthis command takes no arguments"
        EXIT_ERROR
      end

      def boot_ledger
        Hecks.boot(@domain_dir)
      rescue StandardError => e
        abort "the QualityControl ledger did not boot (#{e.class}: #{e.message})"
      end

      # @return [String, nil] `red` or `green` when the commit is on record
      def recorded_verdict(sha)
        row = @runtime.query("QualityControl::MainCheck.All").find { |check| check[:reference][:value] == sha }
        row&.[](:verdict)&.[](:value)
      end

      def answer_recorded(sha, verdict)
        puts "main at #{sha[0, 7]} was already checked: #{verdict}"
        verdict == "red" ? EXIT_FOUND_SOMETHING : EXIT_OK
      end

      def judge(sha, results)
        reds = results.reject(&:passed)
        record!(sha, reds.size)
        return green(sha, results) if reds.empty?

        sweep = record_sweep(sha, results)
        logged = reds.map { |result| log_red(sweep, result, sha) }
        fixes = fix_self_contained(logged)
        red(sha, logged, fixes)
      end

      def record!(sha, count)
        ::QualityControl::MainCheck.record!(reference: { value: sha }, verdict: { value: count.zero? ? "green" : "red" },
                                            red_checks: { value: count })
      end

      def fix_self_contained(logged)
        logged.filter_map do |reference, disposition, fresh|
          next unless fresh && disposition == "self_contained"

          QaFixMainBug.new(runtime: @runtime, root: @root, gate: @gate, shell: @shell).fix(reference).message
        end
      end

      def green(sha, results)
        puts "main at #{sha[0, 7]} is green: #{results.map(&:id).join(", ")}"
        EXIT_OK
      end

      def red(sha, logged, fixes)
        logged.each do |reference, _, fresh|
          puts "#{fresh ? "logged" : "already open"} #{reference} for main at #{sha[0, 7]}"
        end
        fixes.each { |line| puts line }
        EXIT_FOUND_SOMETHING
      end
    end
  end
end
