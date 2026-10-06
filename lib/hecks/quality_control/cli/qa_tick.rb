# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tempfile"
require_relative "child"
require_relative "qa_tick/preflight"
require_relative "qa_tick/output"

module Hecks
  module QualityControlCli
    # The command behind `hecks quality_control sweep.tick`: one QA tick. It needs a clean tree,
    # rebases on `origin/main`, then runs `QaPrCheck`, `QaSweep --all` and `QaGeneratedDomains
    # --from-dials` and prints one report.
    #
    # It exits 2 if any step found something, 1 if none did but a step errored or it refused, 0 if
    # all are clean. The step order is enforced here, not in prose. `QA_REPO_DIR` picks the
    # checkout for the repo steps; `QA_SWEEP_DOMAIN_DIR` is inherited. It never logs bugs, releases
    # holds or opens PRs; those stay with a person or agent.
    class QaTick
      include Preflight
      include Output

      EXIT_OK = 0
      EXIT_ERROR = 1
      EXIT_FOUND_SOMETHING = 2

      USAGE = "usage: hecks quality_control tick"

      # A target's own per-seed "seed N: held (...)" line is the only thing this command ever drops
      # from what it prints, and only where it falls outside a `FOUND SOMETHING`/`OPERATIONAL
      # ERRORS` block. Those two block types are a dispatched subagent's entire input for "On a
      # finding" and "read the actual message(s)" (see the skill), so they are never touched here;
      # the unabridged text is always in the log file this tick writes regardless of what stdout
      # shows.
      HELD_SEED_LINE = /^  seed \d+: held \(.*\)$/

      # Runs the tick.
      #
      # @param argv [Array<String>] no arguments; `--help` prints the usage
      # @param root [String] the repository root
      # @param env [Hash{String => String}] `QA_REPO_DIR` picks the checkout of the repo steps
      # @return [Integer] 2 when a step found something, 1 for an error, 0 when all are clean
      # @raise [SystemExit] when given arguments, the tree is dirty or the rebase stops
      def self.call(argv, root:, env: ENV)
        new(root: root, env: env).call(argv)
      end

      # @param root [String] the repository root
      # @param env [Hash{String => String}] `QA_REPO_DIR` picks the checkout of the repo steps
      def initialize(root:, env: ENV)
        @root = root
        @repo_dir = env.fetch("QA_REPO_DIR", root)
      end

      # @param argv [Array<String>] no arguments; `--help` prints the usage
      # @return [Integer] the exit status
      # @raise [SystemExit] when given arguments, the tree is dirty or the rebase stops
      def call(argv)
        return reject_arguments(argv) unless argv.empty?

        reexec_with_fork_safety
        load_steps
        refuse_unless_ready
        run_steps
      end

      private

      def reject_arguments(argv)
        if %w[-h --help].include?(argv.first)
          puts USAGE
          return EXIT_OK
        end
        abort "#{USAGE}\nthis script takes no arguments — one tick is always the same tick"
      end

      # **A real fork, not a subprocess.** `bundle exec ruby <step>` would re-pay Bundler's gem
      # activation and every `require` above from cold, on top of the boot this process already
      # paid for. `fork` hands the step a copy-on-write child that already has it all loaded, then
      # runs the step's command in it: a genuinely separate OS process, so a crash or an `exit N`
      # inside ends only that child, exactly as it would under a real subprocess.
      #
      # Each step redefining a constant on top of this process's own is harmless, but its warning
      # would clutter every real tick's report, so `$VERBOSE` drops in the child.
      def run_step(command, *argv)
        read, write = IO.pipe
        pid = fork { run_in_child(command, argv, read, write) }
        write.close
        output = read.read
        read.close
        _, status = Process.wait2(pid)
        [output, status.exitstatus]
      end

      def run_in_child(command, argv, read, write)
        read.close
        $stdout.reopen(write)
        $stderr.reopen(write)
        write.close
        $VERBOSE = nil
        exit(command.call(argv))
      end

      def run_steps
        pr_check_output, pr_check_exit = run_pr_check
        sweep_output, sweep_exit = run_sweep
        generated_output, generated_exit = run_generated_domains
        log_path = write_tick_log!(pr_check_output, sweep_output, generated_output)
        report([pr_check_exit, sweep_exit, generated_exit], reclaimed_holds(sweep_output), log_path)
      end

      def run_pr_check
        banner "hecks quality_control check_pull_requests"
        output, exit_code = run_step(->(argv) { QaPrCheck.call(argv, root: @root) })
        puts output
        [output, exit_code]
      end

      def run_sweep
        banner "hecks quality_control ask run --all"
        output, exit_code = run_step(->(argv) { QaSweep.call(argv, root: @root) }, "--all")
        puts condense_sweep_output(output)
        [output, exit_code]
      end

      def run_generated_domains
        banner "hecks quality_control check_generated_domains --from-dials"
        output, exit_code = run_step(->(argv) { QaGeneratedDomains.call(argv, root: @root) }, "--from-dials")
        puts output
        [output, exit_code]
      end

      def reclaimed_holds(sweep_output)
        sweep_output.scan(/^reclaimed stale hold: (\S+)/).flatten
      end
    end
  end
end
