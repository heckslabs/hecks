# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tempfile"
require_relative "child"

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
        unless argv.empty?
          if %w[-h --help].include?(argv.first)
            puts USAGE
            return EXIT_OK
          end
          abort "#{USAGE}\nthis script takes no arguments — one tick is always the same tick"
        end
        reexec_with_fork_safety
        load_steps
        refuse_unless_ready
        run_steps
      end

      private

      # **macOS only, harmless elsewhere.** `fork` below can race Apple's Objective-C runtime
      # initializing a class in a background thread and crash the forked child outright ("may
      # have been in progress in another thread when fork() was called... Crashing instead").
      # Spring's preload-and-fork test runner sets this same flag for the same reason. It has to
      # be in the environment before the Ruby interpreter itself starts, since setting it via
      # `ENV[]` from inside an already-running process is too late (libobjc has already decided by
      # then), so a bare macOS run re-execs itself once with it set,
      # through the same launch form `Child.argv` uses (the process may be a `ruby -e` child,
      # whose `$PROGRAM_NAME` is not a script). Linux has no Objective-C
      # runtime, so this never runs there.
      def reexec_with_fork_safety
        return unless RUBY_PLATFORM.include?("darwin") && !ENV["OBJC_DISABLE_INITIALIZE_FORK_SAFETY"]

        ENV["OBJC_DISABLE_INITIALIZE_FORK_SAFETY"] = "YES"
        exec(*Child.argv(@root, "qa_tick"))
      end

      # **Loaded once, here.** The three steps each `require "hecks"` (plus their own era and
      # fuzzing extras) at their own top. Loading the union up front means every `fork` below
      # hands its step an already-booted Ruby with Bundler's gems already activated and each of
      # these files already in `$LOADED_FEATURES`, so the step's own `require` lines are no-ops
      # instead of a second, third, and fourth cold load of the whole runtime.
      def load_steps
        $LOAD_PATH.unshift File.join(@root, "lib")
        require "hecks"
        require "hecks/ports/persistence/plugins/era"
        require "hecks/fuzzing"
        require "hecks/fuzzing/self_consistency"
        require "hecks/fuzzing/differential"
        require "hecks/fuzzing/era_boundary"
        require "hecks/fuzzing/concurrent_dispatch"
        require "hecks/fuzzing/domain_generator"
        require "hecks/fuzzing/generated_domain_check"
        require "hecks/quality_control/adapters/git_pr"
        require "hecks/quality_control/cli/qa_pr_check"
        require "hecks/quality_control/cli/qa_sweep"
        require "hecks/quality_control/cli/qa_generated_domains"
      end

      def git(*)
        out, err, status = Open3.capture3("git", *, chdir: @repo_dir)
        [out.strip, err.strip, status]
      end

      def banner(title)
        puts
        puts "── #{title} " + ("─" * [0, 70 - title.size].max)
        puts
      end

      def refuse_unless_ready
        banner "worktree (#{@repo_dir})"
        dirty, err, status = git("status", "--porcelain")
        abort "refused: could not read git status at #{@repo_dir} — #{err}" unless status.success?
        unless dirty.empty?
          abort "refused: the working tree is dirty — a tick starts from a clean checkout, never over " \
                "uncommitted work:\n#{dirty}"
        end
        puts "clean"

        banner "git fetch origin && git rebase origin/main"
        out, err, status = git("fetch", "origin")
        abort "refused: git fetch origin failed — #{err.empty? ? out : err}" unless status.success?
        out, err, status = git("rebase", "origin/main")
        unless status.success?
          git("rebase", "--abort")
          abort "refused: git rebase origin/main stopped (aborted, tree restored) — #{err.empty? ? out : err}"
        end
        head, = git("rev-parse", "--short", "HEAD")
        puts "at #{head}"
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
        pid = fork do
          read.close
          $stdout.reopen(write)
          $stderr.reopen(write)
          write.close
          $VERBOSE = nil
          exit(command.call(argv))
        end
        write.close
        output = read.read
        read.close
        _, status = Process.wait2(pid)
        [output, status.exitstatus]
      end

      def collapse_held_lines(text)
        text.gsub(/(?:#{HELD_SEED_LINE}\n)+/) do |run|
          count = run.lines.size
          "  (#{count} held seed(s) suppressed here — none surprised; full detail in the tick's log file)\n"
        end
      end

      # The sweep's `--all` consolidated report is the one step whose bulk section can get
      # large enough to put a relay at risk of truncation (a widened `clean_streak` means hundreds
      # of "seed N: held" lines can precede either a real finding or an unrelated operational
      # error). Everything from the first `OPERATIONAL ERRORS`/`FOUND SOMETHING` header through
      # the end of the last such block is copied verbatim, never summarized or trimmed.
      # `QA_SWEEP_TRACE` output, when present, is routine per-phase timing with no finding in it,
      # so it is left out of stdout (still in the log).
      def condense_sweep_output(raw)
        errors_at = raw.index(/^OPERATIONAL ERRORS \(/)
        found_at = raw.index(/^FOUND SOMETHING \(/)
        trace_at = raw.index(/^QA_SWEEP_TRACE output /)
        protect_from = [errors_at, found_at].compact.min
        return collapse_held_lines(raw) if protect_from.nil?

        protect_to = trace_at || raw.length
        before = collapse_held_lines(raw[0...protect_from])
        protected_block = raw[protect_from...protect_to]
        after =
          if trace_at
            "\n(hecks quality_control ask run's QA_SWEEP_TRACE output omitted here — routine per-phase timing, not a " \
              "finding; the full record is in the tick's log file)\n"
          else
            ""
          end
        "#{before}#{protected_block}#{after}"
      end

      def write_tick_log!(pr_check_output, sweep_output, generated_output)
        dir = File.join(@root, "tmp/qa-tick-logs")
        FileUtils.mkdir_p(dir)
        path = File.join(dir, "#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{Process.pid}.log")
        File.write(path, <<~LOG)
          #{'=' * 72}
          hecks quality_control check_pull_requests -- full raw output
          #{'=' * 72}
          #{pr_check_output}

          #{'=' * 72}
          hecks quality_control ask run --all -- full raw output
          #{'=' * 72}
          #{sweep_output}

          #{'=' * 72}
          hecks quality_control check_generated_domains --from-dials -- full raw output
          #{'=' * 72}
          #{generated_output}
        LOG
        path
      end

      def verdict(code)
        case code
        when EXIT_OK then "clean"
        when EXIT_FOUND_SOMETHING then "FOUND SOMETHING"
        when EXIT_ERROR then "operational error"
        else "exit #{code.inspect}"
        end
      end

      def run_steps
        banner "hecks quality_control check_pull_requests"
        pr_check_output, pr_check_exit = run_step(->(argv) { QaPrCheck.call(argv, root: @root) })
        puts pr_check_output

        banner "hecks quality_control ask run --all"
        sweep_output, sweep_exit = run_step(->(argv) { QaSweep.call(argv, root: @root) }, "--all")
        puts condense_sweep_output(sweep_output)
        reclaimed = sweep_output.scan(/^reclaimed stale hold: (\S+)/).flatten

        banner "hecks quality_control check_generated_domains --from-dials"
        generated_output, generated_exit = run_step(->(argv) { QaGeneratedDomains.call(argv, root: @root) },
                                                    "--from-dials")
        puts generated_output

        log_path = write_tick_log!(pr_check_output, sweep_output, generated_output)
        report([pr_check_exit, sweep_exit, generated_exit], reclaimed, log_path)
      end

      def report(exits, reclaimed, log_path)
        pr_check_exit, sweep_exit, generated_exit = exits
        banner "tick report"
        puts "hecks quality_control check_pull_requests:   #{verdict(pr_check_exit)} (exit #{pr_check_exit.inspect})"
        puts "hecks quality_control ask run --all: #{verdict(sweep_exit)} (exit #{sweep_exit.inspect})"
        puts "hecks quality_control check_generated_domains: #{verdict(generated_exit)} (exit #{generated_exit.inspect})"
        named = reclaimed.empty? ? "" : " (#{reclaimed.join(', ')})"
        puts "stale holds reclaimed: #{reclaimed.size}#{named}"

        tick_exit =
          if exits.include?(EXIT_FOUND_SOMETHING) then EXIT_FOUND_SOMETHING
          elsif exits.all?(EXIT_OK) then EXIT_OK
          else EXIT_ERROR
          end
        puts "tick: #{verdict(tick_exit)} (exit #{tick_exit})"
        puts "full raw output (all three steps, unabridged): #{log_path}"
        tick_exit
      end
    end
  end
end
