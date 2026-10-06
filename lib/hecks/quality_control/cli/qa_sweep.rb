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

      # Default `install_doors` so `QualityControl::Target` and friends are top-level constants.
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

      # Reads the sticky per-check `ever_surprised` bit rather than a loop's local, so a surprise
      # resolved before concluding never reads as clean. `&.` because rows logged before that
      # attribute existed lack the key; missing means no sticky surprise.
      def sweep_was_clean?(sweep)
        sweep.checks.none? { |c| c[:ever_surprised]&.[](:value) == "yes" }
      end

      # Decays the target's yield_score, adds this period's finds, and moves the streak (see
      # `Target.Release`).
      def release_target!(target, capabilities, current_streak, surprises:, clean:)
        next_yield_score = Hecks::Fuzzing::RotationPriority.next_yield_score(
          old_score: target.yield_score.value, surprises_this_period: surprises
        )
        target.release!(now: { value: Time.now.to_i }, yield_score: { value: next_yield_score },
                        next_streak: { value: clean ? current_streak + 1 : 0 },
                        capabilities: { value: capabilities.join(",") })
      end

      # Existence-checked: a held or shelved target is invisible to `Rotation`, and re-`Identify`ing
      # an existing id is refused.
      def seed_default_targets!
        existing = query("Target.All").map { |row| row[:reference][:value] }
        DEFAULT_TARGETS.each do |reference, path|
          next if existing.include?(reference)

          ::QualityControl::Target.identify!(reference: { value: reference }, path: { value: path })
        end
      end

      # The only pick with no name given, where `RotationPriority.pick`'s yield weighting matters
      # (`--all` sweeps every row regardless of order).
      def pick_target_row
        if @target_ref
          row = query("Target.All").find { |r| r[:reference][:value] == @target_ref }
          return row if row

          known = query("Target.All").map { |r| r[:reference][:value] }
          abort "no such target: #{@target_ref.inspect} — known targets: #{known.inspect}"
        end

        rotation = query("Target.Rotation")
        if rotation.empty?
          seed_default_targets!
          rotation = query("Target.Rotation")
        end
        if rotation.empty?
          abort "the rotation is empty even after seeding pizzas/banking — nothing waiting to sweep " \
                "(every known target is currently held or shelved)"
        end

        Hecks::Fuzzing::RotationPriority.pick(rotation, now: Time.now.to_i)
      end

      # One target, start to finish.
      def sweep_one_target
        row = pick_target_row
        @target_reference = row[:reference][:value]
        @target_path = row[:path][:value]
        @domain_path = resolve_target_path(@target_path)
        unless File.directory?(@domain_path)
          abort "target #{@target_reference.inspect} names a path that does not exist on disk: #{@domain_path}"
        end

        # Before the claim: a suspended target cannot be claimed, and must not be until a person
        # runs this.
        return release_suspended_target if @release_mode

        resolve_target_modes
        claim_target
        resolve_depth
        announce_resolution
        open_sweep
        choose_seat
        prepare_scratch_schemas
        announce_sweep
        surprise = run_seeds
        return report_finding(surprise) if surprise

        conclude_clean_sweep
      end

      # Before the claim: an ineligible target is an operational error (exit 1), never a finding,
      # and must not leave the target held. Deferred modes run only when the whole ask is deferred;
      # mixed with others they wait for `--all`'s later wave.
      def resolve_target_modes
        @capabilities = Hecks::Fuzzing::TargetCapabilities.infer(@domain_path, rust_dir: @rust_dir)
        resolved = Hecks::Fuzzing::TargetCapabilities.resolve(@enabled_modes, @capabilities)
        trace("capabilities+resolve")
        explicit_all_deferred = @explicit_modes && !@explicit_modes.empty? &&
                                (@explicit_modes - Hecks::Fuzzing::TargetCapabilities::DEFERRED_MODES).empty?
        @deferred_modes = explicit_all_deferred ? [] : resolved & Hecks::Fuzzing::TargetCapabilities::DEFERRED_MODES
        @active_modes = resolved - @deferred_modes

        if @persistence_parity_mode && !@active_modes.include?(:persistence_parity)
          abort "target #{@target_reference.inspect} (#{@target_path}) declares no persisted_by(\"PostgresEra\") " \
                "binding in its own .hecksagon (capabilities: #{@capabilities.join(",")}) — " \
                "--persistence-parity has nothing to compare Memory against for this domain. " \
                "examples/directory is the known example that qualifies."
        end

        # `era_boundary` is seedless and meaningful with no primary seat; `concurrency` is a seat,
        # so it counts here too.
        unless @active_modes.intersect?(%i[differential ruby_only persistence_parity concurrency era_boundary])
          abort "target #{@target_reference.inspect} (#{@target_path}) resolves no comparison mode at all — " \
                "enabled #{@enabled_modes.join(",")}, capabilities #{@capabilities.join(",")} " \
                "(deferred: #{@deferred_modes.join(",")}). Nothing here can be swept without at least one of " \
                "differential/ruby_only/persistence_parity/concurrency/era_boundary."
        end
        @seeded_modes = @active_modes - SEEDLESS_MODES
      end

      def claim_target
        @target = ::QualityControl::Target.find(@target_reference)
        abort "target #{@target_reference.inspect} vanished between being queried and being claimed" unless @target

        begin
          @target = @target.claim!(held_by: { value: @engineer }, now: { value: Time.now.to_i })
        rescue Hecks::Runtime::GivenNotMet => e
          abort "target #{@target_reference.inspect} is already held and its claim has not gone stale yet " \
                "(#{e.message})"
        end
        trace("claim")
      end

      # Read once after claiming: nothing before `Target.Release` changes `clean_streak`, and it
      # sizes this sweep and seeds `next_streak`.
      def resolve_depth
        @current_streak = @target.clean_streak.value
        default_seeds, default_steps = Hecks::Fuzzing::SweepDepth.for_streak(@current_streak, tiers: @widening_tiers)
        @seeds = @seeds_override || default_seeds
        @steps_per_sequence = @steps_override || default_steps

        # Only when depth is auto-resolved from the streak: an explicit `--seeds N` is a person's
        # manual debugging/reproduction run, and stays the predictable `1..N`. Growing this with the
        # streak is what keeps a matured target's sweep moving into seed integers it has never
        # generated before (see `Hecks::Fuzzing::SweepDepth.seed_offset`).
        @seed_offset = @seeds_override ? 0 : Hecks::Fuzzing::SweepDepth.seed_offset(@current_streak, default_seeds)
        clamp_seeds
      end

      # Clamps down (never up) only for `--persistence-parity`: real PostgresEra I/O per dispatch is
      # expensive even for a target on the widest tier. `concurrency` has a tighter cap: each seed
      # pays for two disposable schemas and a real fork; it is reached via `--modes concurrency`.
      def clamp_seeds
        if @persistence_parity_mode && @seeds > ::QualityControlDials::PERSISTENCE_PARITY_SEED_CAP
          cap = ::QualityControlDials::PERSISTENCE_PARITY_SEED_CAP
          puts "note: --seeds #{@seeds} exceeds QualityControlDials::PERSISTENCE_PARITY_SEED_CAP " \
               "(#{cap}) — clamping down. Real PostgresEra I/O per " \
               "dispatch is genuinely expensive; edit that dial in qa/settings.yml to run more."
          @seeds = cap
        end
        return unless @active_modes.include?(:concurrency) && @seeds > ::QualityControlDials::CONCURRENCY_SEED_CAP

        cap = ::QualityControlDials::CONCURRENCY_SEED_CAP
        puts "note: --seeds #{@seeds} exceeds QualityControlDials::CONCURRENCY_SEED_CAP " \
             "(#{cap}) — clamping down. Each seed forks two real racers against " \
             "real PostgresEra I/O; edit that dial in qa/settings.yml to run more."
        @seeds = cap
      end

      def announce_resolution
        puts "resolved depth: seeds=#{@seeds} steps=#{@steps_per_sequence} (clean_streak=#{@current_streak})"
        puts "seed range: #{@seed_offset + 1}..#{@seed_offset + @seeds}" if @seeded_modes.any?
        line = "resolved modes: #{@active_modes.join(",")} (capabilities=#{@capabilities.join(",")}"
        line += "; deferred=#{@deferred_modes.join(",")}" unless @deferred_modes.empty?
        puts "#{line})"
      end

      # The reference embeds the target: `Sweep` is not scoped to its target, so two sweeps opened
      # in the same second must not collide.
      def open_sweep
        @sweep_reference = "SW-#{@target_reference}-#{Time.now.to_i}"
        @sweep = ::QualityControl::Sweep.open!(target: @target.id, reference: { value: @sweep_reference },
                                               engineer: { value: @engineer })
        @differ = build_differ
        @feature = File.basename(@domain_path).downcase
      end

      # Includes `RustConformanceHelpers` outside RSpec; `structural_skips` collects verbs the
      # binary's manifest declares not generated.
      def build_differ
        require File.join(@root, "spec/support/rust_conformance_helpers")
        Class.new do
          include RustConformanceHelpers

          attr_reader :structural_skips

          def initialize
            @structural_skips = Set.new
          end
        end.new
      end

      # The primary seat is the first of persistence_parity, concurrency, differential, ruby_only
      # that is active, or none for a seedless-only sweep; differential degrades to ruby_only if the
      # build fails.
      def choose_seat
        @binary = nil
        return @mode = :seedless if @seeded_modes.empty?
        return @mode = :persistence_parity if @active_modes.include?(:persistence_parity)
        return @mode = :concurrency if @active_modes.include?(:concurrency)

        @binary = build_rust_binary if @active_modes.include?(:differential)
        return @mode = :differential if @binary

        degrade_to_ruby_only if @active_modes.include?(:differential)
        @mode = :ruby_only
      end

      def build_rust_binary
        @differ.build_rust_for(@feature, @rust_dir)
      rescue RustConformanceHelpers::BuildFailed => e
        @rust_build_failure = e
        nil
      end

      def degrade_to_ruby_only
        # `build_rust_for` answers nil only for an undeclared feature; a declared one that fails
        # raises, so its cargo stderr is printed here.
        reason = @rust_build_failure ? @rust_build_failure.message : "rust/Cargo.toml declares no #{@feature} feature"
        puts "note: no #{@feature} Rust binary — degrading this sweep to ruby_only. Run `hecks project_rust` for it " \
             "and re-sweep.\n#{reason}"
        @active_modes = (@active_modes - %i[differential properties_in_differential structural_skip_report]) |
                        [:ruby_only]
      end

      # Safe under concurrent callers: several sweeps can reach this at once (the parity wave runs
      # up to `QualityControlDials::SWEEP_MAX_PARALLEL` targets in parallel), so the existence check
      # is only a fast-path optimization; the actual safety net is rescuing the create's own race,
      # since two processes can both see the database missing and both attempt `CREATE DATABASE`.
      # Postgres reports that race two different ways: a `duplicate_database` error (42P04) from its
      # own pre-create name check, or, when two backends run that check at nearly the same instant,
      # a raw `unique_violation` (23505) on `pg_database`'s name index once both proceed to insert.
      def ensure_scratch_database!(name)
        admin = PG.connect(dbname: "postgres")
        exists = admin.exec_params("SELECT 1 FROM pg_database WHERE datname = $1", [name]).ntuples.positive?
        admin.exec(%(CREATE DATABASE "#{name}")) unless exists
      rescue PG::DuplicateDatabase, PG::UniqueViolation
        nil
      ensure
        admin&.close
      end

      # The scratch database is a fixed name, created if missing and never dropped (a concurrent
      # sweep may use another schema in it); only this run's uniquely named schemas are dropped, in
      # `drop_scratch_schemas`. `concurrency` needs two: the real fork race and its sequential
      # oracle.
      def prepare_scratch_schemas
        @parity_database = @concurrency_database = SCRATCH_DATABASE
        @parity_schema = @race_schema = @reference_schema = nil
        if @active_modes.include?(:persistence_parity)
          require "pg"
          @parity_schema = "qa_pp_#{@target_reference}_#{Process.pid}_#{SecureRandom.hex(4)}"
          ensure_scratch_database!(@parity_database)
        end
        return unless @active_modes.include?(:concurrency)

        require "pg"
        @race_schema = "qa_cc_race_#{@target_reference}_#{Process.pid}_#{SecureRandom.hex(4)}"
        @reference_schema = "qa_cc_ref_#{@target_reference}_#{Process.pid}_#{SecureRandom.hex(4)}"
        ensure_scratch_database!(@concurrency_database)
      end

      def mode_label
        case @mode
        when :differential then "Ruby vs compiled Rust (#{@feature})"
        when :persistence_parity then "Memory vs real PostgresEra (#{@feature}) — persistence-adapter parity"
        when :concurrency
          "real forked cross-process dispatch vs its own sequential oracle (#{@feature}) — write-lock serialization"
        when :seedless
          "no primary seat (#{@active_modes.join(",")} — audits this target's own real state, generates nothing)"
        else "Ruby-only property/exception check (no compiled Rust binary for #{@feature})"
        end
      end

      def announce_sweep
        if @mode == :seedless
          puts "sweeping #{@target_reference} (#{@target_path}) — #{mode_label}, " \
               "active modes #{@active_modes.join(",")}"
        else
          puts "sweeping #{@target_reference} (#{@target_path}) — #{mode_label}, #{@seeds} seed(s), " \
               "#{@steps_per_sequence} steps each, adversarial fraction #{@adversarial}, role draw #{@role_draw}, " \
               "dry-run fraction #{@dry_run}, active modes #{@active_modes.join(",")}"
        end
      end

      # @return [Hash, nil] the first surprise, or nil when every check held
      def run_seeds
        surprise = nil
        begin
          # One campaign per sweep, resumed from a prior tick's corpus for this exact (target, mode)
          # so guided generation's knowledge compounds across ticks instead of rebuilding an
          # identical corpus from an identical trace every time. Nil when guided generation is off,
          # or this is a seedless-only sweep that will never record anything into it.
          @coverage_path = coverage_corpus_path(@target_reference, @mode) if @guided_generation && @seeded_modes.any?
          @campaign = build_campaign
          surprise = seed_loop
          surprise ||= structural_skip_step
          surprise ||= era_boundary_step
          shrink_surprise(surprise)
        ensure
          # Drops this run's disposable schemas whether the sweep ends clean, surprised or crashes;
          # the databases stay. Persists whatever this run's campaign learned, clean, surprised or
          # crashed alike: the corpus a surprised run built up to that point is still real coverage
          # a later tick should not have to rediscover from scratch.
          drop_scratch_schemas
          save_coverage_state!(@coverage_path, @campaign) if @campaign
        end
        surprise
      end

      def build_campaign
        return unless @coverage_path

        saved = load_coverage_state(@coverage_path)
        if saved
          Hecks::Fuzzing::CoverageCampaign.load(saved, splice_probability: @corpus_splice_probability,
                                                       favor_count:        @favor_rare_verbs)
        else
          Hecks::Fuzzing::CoverageCampaign.new(splice_probability: @corpus_splice_probability,
                                               favor_count:        @favor_rare_verbs)
        end
      end

      # A seedless-only sweep skips the loop so it never claims to have generated sequences.
      def seed_loop
        return unless @seeded_modes.any?

        surprise = nil
        ((@seed_offset + 1)..(@seed_offset + @seeds)).each do |seed|
          result = run_one_seed(@mode, seed)
          @campaign.record(seed, result[:plan], result[:trace]) if @campaign && result[:trace]

          surprised = log_seed_checks(result)
          if surprised.empty?
            puts "  seed #{seed}: held (#{result[:checks].map { |c| c[:mode] }.join(", ")})"
            next
          end

          puts "  seed #{seed}: SURPRISED (#{surprised.map { |c| c[:mode] }.join(", ")})"
          surprise = result.merge(seed: seed, checks: surprised)
          break
        end
        puts "  #{@campaign.summary}" if @campaign
        surprise
      end

      # Every mode's check is logged before the loop decides, so a seed that held differentially but
      # surprised on properties records both.
      #
      # @return [Array<Hash>] the checks that surprised
      def log_seed_checks(result)
        result[:checks].reject do |check|
          log_and_mark(check)
          check[:clean]
        end
      end

      def log_and_mark(check)
        @sweep = log_check!(@sweep, subject: check[:subject], expectation: check[:expectation])
        sequence = @sweep.checks.last[:sequence][:value]
        if check[:clean]
          mark_held!(@sweep, sequence, check[:observation])
        else
          mark_surprised!(@sweep, sequence, check[:observation], @target_reference)
        end
      end

      # Structural-skip check only after a differential loop that ran clean to the end.
      def structural_skip_step
        return unless @mode == :differential && @active_modes.include?(:structural_skip_report)

        check = structural_skip_check(@differ, @binary, @structural_boundary)
        log_and_mark(check)
        if check[:clean]
          puts "  structural skips: #{check[:observation]}"
          nil
        else
          puts "  structural skips: SURPRISED — #{check[:observation]}"
          { seed: nil, steps: [], checks: [check] }
        end
      end

      # Era-boundary check, once per sweep, independent of the primary seat; skipped once anything
      # surprised. A target with no lineage logs no Check: holding one would report an unaudited
      # target as clean.
      def era_boundary_step
        return unless @active_modes.include?(:era_boundary)

        check = era_boundary_check(@domain_path)
        if check[:skip]
          puts "  era boundary: #{check[:observation]} — no Check logged"
          return nil
        end

        log_and_mark(check)
        if check[:clean]
          puts "  era boundary: #{check[:observation]}"
          nil
        else
          puts "  era boundary: SURPRISED — #{check[:observation]}"
          { seed: nil, steps: [], checks: [check] }
        end
      end

      # Shrinks inside the guarded block: the parity schema is dropped afterwards, and candidates
      # need it.
      def shrink_surprise(surprise)
        return unless surprise && surprise[:seed] && @shrink_budget.positive?

        surprise[:shrunk] = surprise[:checks].filter_map do |check|
          next unless SHRINKABLE_MODES.include?(check[:mode])

          puts "  shrinking [#{check[:mode]}] (#{surprise[:steps].size} steps, budget #{@shrink_budget})…"
          shrink_check(check, @mode, surprise[:steps])
        end
      end

      def drop_scratch_schemas
        if @parity_schema
          admin = PG.connect(dbname: @parity_database)
          admin.exec("SET client_min_messages = warning")
          admin.exec("DROP SCHEMA IF EXISTS #{admin.quote_ident(@parity_schema)} CASCADE")
          admin.close
        end
        return unless @race_schema || @reference_schema

        admin = PG.connect(dbname: @concurrency_database)
        admin.exec("SET client_min_messages = warning")
        [@race_schema, @reference_schema].compact.each do |schema|
          admin.exec("DROP SCHEMA IF EXISTS #{admin.quote_ident(schema)} CASCADE")
        end
        admin.close
      end

      def report_finding(surprise)
        print_finding(surprise)
        EXIT_FOUND_SOMETHING
      end

      # Reached only when every seed held; re-reads the sticky `ever_surprised` bit, not the loop's
      # local.
      def conclude_clean_sweep
        notes = "domain=#{@target_reference} path=#{@target_path} mode=#{@mode} modes=#{@active_modes.join(",")} " \
                "capabilities=#{@capabilities.join(",")} feature=#{@feature} seeds=#{@seeds} " \
                "steps=#{@steps_per_sequence} adversarial=#{@adversarial} role_draw=#{@role_draw} " \
                "dry_run=#{@dry_run} — every seed held, no divergence or property violation found."
        @sweep.conclude!(notes: { value: notes })
        trace("seed loop+conclude")

        target = release_target!(@target, @capabilities, @current_streak, surprises: 0,
                                                                          clean:     sweep_was_clean?(@sweep))
        trace("release")

        puts
        puts "clean — #{@target_reference} concluded and released. clean_streak: #{@current_streak} -> " \
             "#{target.clean_streak.value}. capabilities: #{target.capabilities.value.inspect}"
        puts notes
        EXIT_OK
      end
    end
  end
end
