# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "securerandom"
require "tempfile"
require_relative "../../../hecks"
# The era/lineage plugin does not load with core (ADR 0033); the ledger's binding needs it.
require_relative "../../ports/persistence/plugins/era"
require_relative "../../fuzzing"
require_relative "../../fuzzing/self_consistency"
require_relative "../../fuzzing/differential"
require_relative "../../fuzzing/era_boundary"
require_relative "../../fuzzing/concurrent_dispatch"
require_relative "qa_sweep/parsing"
require_relative "qa_sweep/all_mode"
require_relative "qa_sweep/checks"
require_relative "qa_sweep/dials"
require_relative "qa_sweep/release_mode"
require_relative "qa_sweep/finding_report"
require_relative "qa_sweep/target_setup"
require_relative "qa_sweep/depth"
require_relative "qa_sweep/seat"
require_relative "qa_sweep/scratch"
require_relative "qa_sweep/seed_loop"
require_relative "qa_sweep/conclusion"

module Hecks
  module QualityControlCli
    # The command behind `hecks quality_control query sweep.run`: runs one claim, sweep, conclude
    # and release cycle against a `QualityControl` target (`USAGE` lists the forms, from a bare
    # sweep of the least recently swept target to `--all` and `--release`). It stops with a report
    # and exit 2 on the first surprised check, and never logs a `Bug` itself.
    #
    # Exit codes: 0 clean; 1 operational error; 2 found something (the sweep stays open and the
    # target is suspended by the ledger's `SuspendOnSurprise` policy until `--release`).
    #
    # `QA_SWEEP_DOMAIN_DIR` boots a throwaway ledger instead of `qa/bluebook` and is inherited by
    # `--all` children; `QA_SWEEP_RUST_DIR` points differential mode at a fixture crate;
    # `QA_SWEEP_COVERAGE_CORPUS_DIR` points the coverage corpus at a throwaway directory;
    # `QA_SWEEP_TRACE=1` prints a per-phase stderr timer.
    class QaSweep
      EXIT_OK = 0
      EXIT_ERROR = 1
      EXIT_FOUND_SOMETHING = 2

      USAGE = "usage: hecks quality_control ask run [target=<reference>] arguments=\"[--seeds N] [--steps N] " \
              "[--adversarial FRACTION] [--role-draw FRACTION] [--dry-run FRACTION] " \
              "[--self-consistency true|false] [--modes a,b,c]\"\n       " \
              "arguments=\"--all [--seeds N] [--steps N] [--adversarial FRACTION] [--role-draw FRACTION] " \
              "[--dry-run FRACTION] [--self-consistency true|false] [--modes a,b,c] [--no-parity]\"\n       " \
              "target=<reference> arguments=\"--persistence-parity [--seeds N]\"\n       " \
              "target=<reference> arguments=\"--release --notes 'what a person concluded, 40+ chars'\""

      # Modes run when the ledger declares no `QualityControlDials::MODES` (an isolated spec's
      # fixture).
      DEFAULT_MODES = %i[differential ruby_only self_consistency properties_in_differential
                         structural_skip_report persistence_parity].freeze

      DEFAULT_TARGETS = { "pizzas" => "examples/pizzas", "banking" => "examples/banking" }.freeze

      # Modes with no per-seed loop; when only these are active the seed machinery is skipped.
      SEEDLESS_MODES = %i[era_boundary].freeze

      # The disposable scratch database the parity and concurrency modes create schemas in.
      SCRATCH_DATABASE = "hecks_qa_persistence_parity"

      include Parsing
      include AllMode
      include Checks
      include Dials
      include ReleaseMode
      include FindingReport
      include TargetSetup
      include Depth
      include Seat
      include Scratch
      include SeedLoop
      include Conclusion

      # Sweeps.
      #
      # @param argv [Array<String>] the flags in the usage line
      # @param root [String] the repository root
      # @param env [Hash{String => String}] the `QA_SWEEP_*` variables
      # @return [Integer] 0 clean, 2 found something, 1 an operational error
      # @raise [SystemExit] on a bad argument or a refused sweep
      def self.call(argv, root:, env: ENV)
        new(root: root, env: env).call(argv)
      end

      # @param root [String] the repository root
      # @param env [Hash{String => String}] the `QA_SWEEP_*` variables
      def initialize(root:, env: ENV)
        @root = root
        @domain_dir = env.fetch("QA_SWEEP_DOMAIN_DIR", File.join(root, "qa/bluebook"))
        @rust_dir = env.fetch("QA_SWEEP_RUST_DIR", File.join(root, "rust"))
        @coverage_corpus_dir = env.fetch("QA_SWEEP_COVERAGE_CORPUS_DIR", File.join(root, "tmp/qa-coverage-corpus"))
        @trace_enabled = env["QA_SWEEP_TRACE"] == "1"
      end

      # @param argv [Array<String>] the flags in the usage line
      # @return [Integer] the exit status
      # @raise [SystemExit] on a bad argument or a refused sweep
      def call(argv)
        @trace_last = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        trace("require")
        return EXIT_OK if parse_arguments(argv.dup) == :help

        @runtime = boot_ledger
        trace("ledger boot")
        read_dials
        resolve_enabled_modes
        return run_all_mode(modes: @enabled_modes, parity_wave: parity_wave?, deferred_wave_modes: deferred_waves) if @all_mode

        sweep_one_target
      end

      private

      # Prints a per-phase stderr timer under `QA_SWEEP_TRACE=1`; each print is the delta since the
      # previous mark.
      def trace(label)
        return unless @trace_enabled

        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        warn format("[qa_sweep_trace pid=%<pid>d] %<label>-24s +%<delta>6.3fs",
                    pid: Process.pid, label: label, delta: now - @trace_last)
        @trace_last = now
      end

      # Default `install_driving` so `QualityControl::Target` and friends are top-level constants.
      def boot_ledger
        Hecks.boot(@domain_dir)
      rescue StandardError => e
        abort "the QualityControl ledger did not boot — fix the ledger itself before sweeping against it " \
              "(#{e.class}: #{e.message})"
      end

      def query(name, **args) = @runtime.query("QualityControl::#{name}", **args)

      # A stored `Target.path` is either relative to this repo's root (the common case) or an
      # absolute path to a real external checkout. `File.join(root, path)` does not special-case an
      # absolute second argument the way `File.expand_path` does, so an absolute path would
      # otherwise be silently mangled. It matches `QaDiscoverExternalDomains`'s own normalization.
      def resolve_target_path(path)
        path.start_with?("/") ? File.expand_path(path) : File.expand_path(path, @root)
      end

      # A target reference may itself contain `/` (`hecks quality_control
      # target.discover_external_domains` suggests `repo/entity`-shaped references for an external
      # domain), but every reference also gets folded into a single filename component: a log
      # prefix, a shrunk-repro filename, a coverage-corpus filename. Left raw, an embedded `/` is
      # read as an extra path segment that nothing creates, breaking the write. This never changes
      # what is stored as the
      # `Target`/`Sweep` reference itself.
      def filesystem_safe_component(reference)
        reference.gsub(/[^A-Za-z0-9_.-]/, "-")
      end

      # One target, start to finish.
      def sweep_one_target
        select_target
        # Before the claim: a suspended target cannot be claimed, and must not be until a person
        # runs this.
        return release_suspended_target if @release_mode

        resolve_target_modes
        claim_target
        prepare_sweep
        surprise = run_seeds
        return report_finding(surprise) if surprise

        conclude_clean_sweep
      end

      # Everything between the claim and the first seed.
      def prepare_sweep
        resolve_depth
        announce_resolution
        open_sweep
        choose_seat
        prepare_scratch_schemas
        announce_sweep
      end
    end
  end
end
