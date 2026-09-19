require "fileutils"
require "tmpdir"
require "tempfile"
require "json"
require_relative "isolated_boot"
require_relative "../naming"

module Hecks
  module Fuzzing
    # A GENERATED SEQUENCE, RACED FOR REAL — `spec/adapters/driven/
    # postgres_era_concurrent_dispatch_spec.rb` proves ADR 0036's own fix
    # (a real `pg_advisory_xact_lock` serializes a PostgresEra-bound
    # dispatch across separate OS processes) against ONE hand-authored
    # fixture and ONE hand-picked conflicting pair (two `$6,000` Debits
    # against a `$10,000` account). This module asks the SAME question —
    # does the cross-process write lock actually serialize concurrent
    # writers? — of an ARBITRARY generated sequence against a REAL target
    # domain, so the practice's own adversarial generator gets to pick the
    # conflict instead of a human picking it once and never again.
    #
    # THE MECHANISM, GENERALIZED FROM THAT SPEC RATHER THAN REDERIVED: a
    # command step partway through a generated sequence is chosen as the
    # RACE STEP; every step before it is SETUP (replayed once, sequentially,
    # to bring a fresh disposable schema to the state the race step expects
    # to act against); the race step is then dispatched TWICE — once from
    # each of two real, separate, forked OS processes racing against that
    # SAME schema, no artificial gating, whichever the scheduler favors.
    #
    # THE ORACLE IS THE SAME PAIR, DISPATCHED SEQUENTIALLY, NOT A
    # HARDCODED EXPECTATION — unlike the hand-authored spec (which can
    # assert `%w[refused succeeded]` because it knows its own fixture's
    # business rule), this module has no idea whether an arbitrary
    # generated race step conflicts with itself at all. So it asks the
    # DOMAIN: replay the identical setup on a SEPARATE fresh schema, then
    # dispatch the SAME race step twice, one after the other, in one
    # process, with no contention at all — genuinely correct by
    # construction, since nothing else can touch that schema while it
    # runs. Two conflicting writes settle as {"succeeded", "refused"};
    # two independent ones settle as {"succeeded", "succeeded"}; either
    # way, THAT is the multiset the concurrent pair must also produce if
    # the write lock actually serializes them — order does not matter
    # (which real racer wins a genuine race is never controlled), the SET
    # of outcomes does.
    #
    # WHAT A BROKEN LOCK LOOKS LIKE HERE: the concurrent pair settling as
    # {"succeeded", "succeeded"} where the sequential oracle says
    # {"succeeded", "refused"} — two processes each hydrated the
    # pre-write state, neither saw the other's write, and the second
    # commit landed as a silent lost update instead of failing its own
    # `given`. That is the EXACT corruption class ADR 0036 fixed for
    # PostgresEra and `postgres_concurrent_dispatch_spec.rb` still
    # documents, unfixed, for plain Postgres.
    #
    # NOT A REPLACEMENT for the hand-authored spec — that spec proves the
    # mechanism once, precisely, with controlled gating so the assertion
    # is deterministic; this module proves the SAME mechanism holds for
    # whatever a real domain's own generated sequences throw at it, with
    # no gating (a genuine, ungated race), on every sweep this mode runs.
    module ConcurrentDispatch
      module_function

      COMMAND_STEP = ->(step) { step["verb"] && !step["query"] && !step["dry_run"] }

      # ONE DIVERGENCE LIST, THE SAME SHAPE EVERY OTHER MODE IN THIS
      # PRACTICE PRODUCES — `[]` when nothing was found (including the
      # legitimate "this seed's generated sequence has no command step to
      # race at all" case: a sequence of pure queries/dry-runs has nothing
      # to concurrently dispatch, and that is not a finding).
      #
      # `database:` is the shared, never-dropped scratch database
      # (`bin/qa_sweep`'s own `persistence_parity_database`, reused here
      # for the identical reason: a container, not the thing that's
      # unique per run). `race_schema:`/`reference_schema:` are two
      # DIFFERENT disposable schema names this ONE call owns for its own
      # duration — the caller creates neither ahead of time (both are
      # wiped fresh by the boots below) and drops both afterward, the
      # same lifecycle `persistence_parity_schema` already has.
      def check(domain_path, steps, database:, race_schema:, reference_schema:)
        normalized = steps.map { |step| step.transform_keys(&:to_s) }
        lockable, probe_errors = lockable_verbs(domain_path, normalized, database: database, schema: reference_schema)
        race_index = pick_race_index(normalized, lockable)
        unless race_index
          # `[]` HERE MEANS "NOTHING TO RACE", AND MUST ONLY EVER MEAN THAT.
          # A sequence of pure queries/dry-runs is a legitimate clean
          # result; a probe that raised for every verb is not — that one
          # used to produce the identical `[]` and be logged as a clean
          # concurrency Check (see `lockable_verbs`).
          return [] if probe_errors.empty?

          return [{ field:  "concurrency_unraceable",
                    detail: "no command step could be raced because the cross-process-lock probe failed: " \
                            "#{probe_errors.uniq.join('; ')}" }]
        end

        setup_steps = normalized[0...race_index]
        race_step   = normalized[race_index]

        reference  = reference_outcomes(domain_path, setup_steps, race_step, database: database, schema: reference_schema)
        concurrent = concurrent_outcomes(domain_path, setup_steps, race_step, database: database, schema: race_schema)

        divergences_for(race_step, reference, concurrent)
      rescue StandardError => e
        [{ field: "process", detail: "#{e.class}: #{e.message}" }]
      end

      # THE COMMAND STEP CLOSEST TO THE MIDDLE OF THE SEQUENCE — not the
      # first (racing a bare identity-creation with no setup at all is a
      # legitimate, useful case, so index 0 is not excluded) and not
      # chosen for any domain-specific reason: a mid-sequence step has, on
      # average, the deepest state to act against and the best odds of
      # actually conflicting with itself. `nil` when the generated
      # sequence has no command step at all (every step a query or a dry
      # run) — nothing here for this seed to race.
      #
      # `lockable_verbs` — OPTIONAL, but `check` always passes one: the
      # set of verbs whose OWN aggregate is actually bound to an adapter
      # that declares `:cross_process_lock` in THIS domain (see
      # `lockable_verbs` below for why this can't be assumed just because
      # the domain binds SOME of its own aggregates to PostgresEra).
      # Racing anything outside that set is not a legitimate race at
      # all — nil when nothing eligible is left, same as the "no command
      # step" case, never a finding of its own.
      def pick_race_index(steps, lockable_verbs = nil)
        command_indices = steps.each_index.select { |i| COMMAND_STEP.call(steps[i]) }
        command_indices = command_indices.select { |i| lockable_verbs.include?(steps[i]["verb"]) } if lockable_verbs
        return nil if command_indices.empty?

        command_indices[command_indices.size / 2]
      end

      # WHICH OF THIS SEQUENCE'S OWN COMMAND VERBS ARE EVEN CANDIDATES TO
      # RACE — BUG#142 (SW-quality_control-1789768606's own first real
      # concurrency run, seed 3): a domain that `persisted_by("PostgresEra")`
      # binds ITS OWN aggregates is not thereby binding a framework
      # member it merely `uses_framework`s — `hecksagon_builder.rb`'s own
      # `uses_framework` loads only that member's SHAPE, never its
      # persistence (see `examples/banking/bluebook/banking.hecksagon`'s
      # own comment: a framework member's aggregates need a SIBLING
      # hecksagon, registered under THAT member's own name, or
      # `Ports::Persistence::BindingPolicy.default_binding` silently
      # gives them "Memory" — no hecksagon registered under that name at
      # all, so `resolve`'s own `missing_binding` refusal (which only
      # fires when a hecksagon EXISTS for that domain and simply omits
      # this aggregate) never gets a chance to say so).
      # `qa/bluebook/quality_control.hecksagon` attaches `Governance` via
      # `uses_framework` with no such sibling — `Governance::
      # RoleAssignment`/`RoleTransition` are Memory-backed, process-
      # local, in the real ledger, `concurrency` mode included. Racing a
      # Memory-backed aggregate across two real OS processes can never
      # agree with the single-process sequential oracle — each racer's
      # own boot gets its own independent, empty store — no matter how
      # correct any write lock is; that is a guaranteed false positive,
      # not evidence of a broken lock.
      #
      # Boots the SAME PostgresEra-rebound copy the race itself boots
      # (`boot_preserving_schema` — structural inspection only, nothing
      # dispatched, so the schema it's given is left exactly as it found
      # it) and asks each distinct command verb's own resolved repository
      # whether it actually declares `:cross_process_lock` — the same
      # capability `Interpreting#run_dispatch_order_with_isolation`
      # itself keys off of to decide whether a real advisory lock is
      # even in play for that aggregate. A verb this boot can't resolve
      # at all (a malformed adversarial verb, say) is conservatively
      # excluded, not raced on a guess.
      # ANSWERS `[lockable, probe_errors]`. The errors half exists because
      # the probe below rescues to `false`: a verb that cannot be RESOLVED
      # is indistinguishable, from the outside, from one that resolves fine
      # and simply declares no `:cross_process_lock`. If resolution broke
      # for every verb (a renamed capability symbol, a wiring change),
      # `lockable` came back empty, `check` returned `[]`, and the sweep
      # logged a CLEAN concurrency Check for a race that never happened.
      # `check` reports that case now instead of holding it.
      def lockable_verbs(domain_path, steps, database:, schema:)
        verbs = steps.select { |step| COMMAND_STEP.call(step) }.map { |step| step["verb"] }.uniq
        lockable = []
        probe_errors = []
        boot_preserving_schema(domain_path, database: database, schema: schema) do |copy|
          runtime = Hecks.boot(copy)
          verbs.each do |verb|
            lockable << verb if verb_cross_process_lockable?(runtime, verb, probe_errors)
          end
        end
        [lockable, probe_errors]
      end

      def verb_cross_process_lockable?(runtime, verb, probe_errors = [])
        domain, aggregate_name, = Naming.split_verb(verb)
        return false unless domain && aggregate_name

        aggregate = runtime.registry.bluebook(domain)&.aggregate(aggregate_name)
        return false unless aggregate

        repository = runtime.registry.repository(domain, aggregate)
        repository.capabilities.include?(:cross_process_lock)
      rescue StandardError => e
        # STILL `false` — a verb this boot cannot resolve is not raced on a
        # guess — but no longer SILENT: `check` needs to tell "nothing here
        # declares a cross-process lock" from "asking broke".
        probe_errors << "#{verb}: #{e.class}: #{e.message}"
        false
      end

      def divergences_for(race_step, reference, concurrent)
        crashes = (reference + concurrent).select { |outcome| outcome.start_with?("crashed:") }.uniq
        return crashes.map { |c| { field: "concurrency_crash", verb: race_step["verb"], detail: c } } if crashes.any?

        return [] if reference.sort == concurrent.sort

        [{ field: "concurrency_race", verb: race_step["verb"], reference: reference, concurrent: concurrent,
           detail: "two concurrent cross-process dispatches of #{race_step['verb']} settled as #{concurrent.sort} " \
                   "where the identical pair, dispatched sequentially with no contention, settled as " \
                   "#{reference.sort} — the cross-process write lock did not correctly serialize this write" }]
      end

      # THE ORACLE — one boot, one process, the setup then the race step
      # TWICE in immediate succession. Nothing else ever touches this
      # schema while this runs, so whatever the domain itself settles on
      # is correct by construction, not asserted.
      def reference_outcomes(domain_path, setup_steps, race_step, database:, schema:)
        outcomes = []
        IsolatedBoot.call(domain_path, adapter: :postgres_era, database: database, schema: schema) do |copy|
          runtime = Hecks.boot(copy)
          dispatch_all!(runtime, setup_steps)
          outcomes << dispatch_one(runtime, race_step)
          outcomes << dispatch_one(runtime, race_step)
        end
        outcomes
      end

      # THE RACE ITSELF — setup runs ONCE, sequentially, in THIS process
      # (the same `IsolatedBoot.call` wipe-then-boot every other mode
      # here already uses), and only THEN do the two real racers run.
      # Each racer boots its OWN fresh copy of the domain against the
      # SAME now-populated schema — `boot_preserving_schema`, below,
      # deliberately skips the wipe `IsolatedBoot.call` always does, or
      # the setup this line just wrote would be gone before either racer
      # ever dispatched anything.
      #
      # REAL, SEPARATE OS PROCESSES, NOT `Thread.new` — `postgres_era_
      # concurrent_dispatch_spec.rb`'s own header explains why:
      # `Runtime::AggregateLock`'s in-process registry would fully (and
      # misleadingly) serialize two THREADS sharing one process even with
      # the cross-process lock fix reverted. Only two genuinely separate
      # OS processes exercise the gap this check exists to catch.
      #
      # `Process.spawn`, NOT `Process.fork` — `bin/qa_sweep`'s own
      # top-of-file comment on `--all` names the identical hazard this
      # sidesteps: by the time a `concurrency` seed runs, THIS process
      # already holds the QualityControl ledger's own live PostgresEra
      # connection (this module's own caller, `bin/qa_sweep`, booted it
      # long before any seed ran). `Process.fork` duplicates every open
      # file descriptor, SSL session state included — confirmed live
      # while wiring this mode up: forking directly from here corrupted
      # the LEDGER's own connection the moment either racer child exited,
      # surfacing on the NEXT unrelated ledger write, nowhere near this
      # method's own code. `bin/qa_concurrency_racer` is this method's own
      # worker, one real `ruby` process per racer — read that script's own
      # header for the rest of this reasoning.
      def concurrent_outcomes(domain_path, setup_steps, race_step, database:, schema:)
        IsolatedBoot.call(domain_path, adapter: :postgres_era, database: database, schema: schema) do |copy|
          dispatch_all!(Hecks.boot(copy), setup_steps)
        end

        root = File.expand_path("../../..", __dir__)
        racer = File.join(root, "bin/qa_concurrency_racer")
        args_json = JSON.generate(race_step["args"] || {})
        logs = Array.new(2) { Tempfile.new(["qa-concurrency-racer-", ".log"]) }
        logs.each(&:unlink)

        pids = logs.map do |log|
          Process.spawn("bundle", "exec", "ruby", racer, domain_path, database, schema, race_step["verb"], args_json,
                        out: log, err: log, chdir: root)
        end

        pids.each { |pid| Process.wait(pid) }
        logs.map do |log|
          log.rewind
          output = log.read
          log.close
          output.strip.empty? ? "crashed:no output from bin/qa_concurrency_racer" : output.lines.last.chomp
        end
      end

      # ONE STEP, ONE OUTCOME — never raises: a declared domain refusal is
      # "refused" (the expected, ordinary answer a `given`/invariant can
      # give), anything else escaping is "crashed:<class>: <message>", a
      # genuine finding this module's own caller surfaces rather than lets
      # kill a forked racer silently.
      def dispatch_one(runtime, step)
        args = (step["args"] || {}).transform_keys(&:to_sym)
        runtime.dispatch_flat(step["verb"], args)
        "succeeded"
      rescue *Hecks::Runtime::DOMAIN_REFUSALS, Hecks::Bluebook::Expression::EvaluationError
        "refused"
      rescue StandardError => e
        "crashed:#{e.class}: #{e.message}"
      end

      # SETUP TOLERATES AN ORDINARY REFUSAL (a generated sequence's own
      # earlier step can legitimately refuse — every other mode in this
      # practice already replays a prefix that way) but never a crash: an
      # unexpected exception during setup means the schema this race is
      # about to run against is in an unknown state, which is itself
      # worth surfacing, not silently racing anyway.
      def dispatch_all!(runtime, steps)
        steps.each do |step|
          outcome = dispatch_one(runtime, step)
          raise "setup step #{step['verb']} #{outcome}" if outcome.start_with?("crashed:")
        end
      end

      # THE SAME COPY-AND-REBIND `IsolatedBoot.call(..., adapter:
      # :postgres_era, ...)` DOES, MINUS THE SCHEMA WIPE — deliberately
      # NOT reusing `IsolatedBoot.rebind_to_postgres_era!` itself, which
      # bundles `ensure_postgres_era_schema!`'s own `DROP SCHEMA` into the
      # same call with no way to opt out (see that method's own header:
      # the wipe is the "zero-history guarantee every other adapter mode
      # already gives," exactly the guarantee THIS caller must NOT have —
      # the whole point of a race is booting against what setup already
      # wrote). `copy_dereferencing`/`rewrite_bindings!` are the same two
      # public steps that method itself calls first; only the `.world`
      # this writes is duplicated from it, not re-derived, because the
      # shape a `PostgresEra`-bound copy's `.world` needs is exactly that
      # method's own, one step short.
      def boot_preserving_schema(domain_path, database:, schema:)
        Dir.mktmpdir("hecks-concurrency") do |tmp|
          copy = File.join(tmp, File.basename(domain_path))
          IsolatedBoot.copy_dereferencing(domain_path, copy)
          FileUtils.rm_rf(File.join(copy, "data"))
          IsolatedBoot.rewrite_bindings!(copy, "PostgresEra")
          write_postgres_era_world!(copy, database: database, schema: schema)
          yield copy
        end
      end

      def write_postgres_era_world!(copy, database:, schema:)
        Dir.glob(File.join(copy, "**", "*.hecksagon")).each do |hecksagon_path|
          names = File.read(hecksagon_path).scan(/Hecks\.hecksagon\s+"([^"]+)"/).flatten.uniq
          next if names.empty?

          world_path = File.join(File.dirname(hecksagon_path), "hecks_fuzz_postgres_era.world")
          File.write(world_path, names.map do |name|
            <<~WORLD
              Hecks.world "#{name}" do
                persisted_by("PostgresEra") do
                  database "#{database}"
                  schema "#{schema}"
                  allow_superuser true
                end
              end
            WORLD
          end.join("\n"))
        end

        Dir.glob(File.join(copy, "**", "*.world")).each do |path|
          File.delete(path) unless File.basename(path) == "hecks_fuzz_postgres_era.world"
        end
      end
    end
  end
end
