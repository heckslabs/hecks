# Shared between spec/rust_conformance_spec.rb (the fixed, hand-authored
# corpus) and spec/rust_conformance_fuzz_spec.rb (PRD 04 — the same
# differential check, run against SequenceGenerator's own randomly
# generated sequences instead). Factored out so the two never drift on
# what "a known, understood boundary, not a bug" means — that judgment is
# real, cited, and earned per case (see rust_conformance_spec.rb's own
# extensive comments on each), and belongs in exactly one place.
#
# `@build_cache`'s own header (below) already explains why ONE process
# building `--features X` then `--features Y` back to back is unsafe —
# `bin/qa_sweep --all` (see that script's own header on why) is what made
# a SECOND, worse version of the same problem real: several
# `bin/qa_sweep <target>` invocations, each its OWN OS process with its
# OWN empty `@build_cache`, now genuinely run `cargo build --features X`
# and `cargo build --features Y` AT THE SAME TIME rather than back to
# back. `cargo build` itself is safe under that — it holds its own lock
# over `target/` and simply serializes the two real compiles — but this
# method's OWN critical section is not: `system("cargo build", ...)`
# always writes to the SAME shared `target/debug/rust` path no matter
# which feature was requested, and only THIS method's own next two lines
# (`FileUtils.cp` to the per-feature pinned path) rescue that shared
# artifact before it can be overwritten again. Between one process's
# `system` call returning and its own `FileUtils.cp` running, nothing
# used to stop a SECOND process's `cargo build` for a DIFFERENT feature
# from finishing first and overwriting `target/debug/rust` out from under
# it — the first process would then pin the SECOND process's binary under
# its OWN feature's name, and a differential fuzz run would silently diff
# Ruby against the wrong domain's Rust, either crashing on shape mismatch
# or — worse — looking clean by accident. `File.flock`, taken over the
# whole build-then-pin section below and released before this method
# returns, closes that window: two processes can still both run `cargo
# build` freely (cargo's own lock already handles that), but only one at
# a time is ever between "cargo finished" and "the right binary is
# safely copied out" for this rust_dir — matching this repository's own
# established answer to "two processes, one shared piece of state" (the
# real Postgres advisory lock `PostgresEra#with_write_lock` takes for the
# identical reason, `lib/hecks/runtime/interpreting.rb`'s own comment).
require "fileutils"

module RustConformanceHelpers
  # PROCESS-WIDE, keyed on [rust_dir, domain_feature] — not per-example
  # and not per-file. `spec_helper.rb`'s `config.order = :random`
  # interleaves examples from every file in a single `rspec` process, so
  # without this, a run touching rust_conformance_spec.rb's 22 fixtures
  # (20 banking, 1 pizzas, 1 roster) plus rust_conformance_fuzz_spec.rb's
  # 2 domains could interleave `--features banking` and `--features
  # pizzas` calls in effectively any order. `cargo build --features X`
  # immediately after a `--features Y` build forces a REAL recompile of
  # every feature-gated compilation unit, not just a relink — measured
  # live as the single largest chunk of CI's slowest job
  # (rspec_rust_io's own rspec step, ~7m18s of the workflow's ~9m19s
  # critical path). Building once per (rust_dir, domain_feature) and
  # reusing the result for every later call collapses what could be
  # dozens of real recompiles down to one per domain actually exercised.
  @build_cache = {}

  class << self
    attr_reader :build_cache
  end

  # Built for THIS fixture/sequence's own domain — but only the FIRST
  # time a given (rust_dir, domain_feature) pair is requested; every
  # later call for the same pair returns the memoized result with no
  # cargo invocation at all. See the module-level comment above for why
  # this replaced "never found by trusting whatever happens to already
  # sit at rust/target/{release,debug}/rust" — that discipline is still
  # honored (nothing here trusts an AMBIENT binary left over from a
  # previous rspec run or another process), it's just no longer re-paid
  # on every single call within this one.
  def build_rust_for(domain_feature, rust_dir)
    cache = RustConformanceHelpers.build_cache
    cache_key = [rust_dir, domain_feature]
    return cache[cache_key] if cache.key?(cache_key)

    cargo_toml = File.read(File.join(rust_dir, "Cargo.toml"))
    return cache[cache_key] = nil unless cargo_toml =~ /^#{Regexp.escape(domain_feature)}\s*=\s*\[\]/

    cache[cache_key] = build_and_pin(domain_feature, rust_dir)
  end

  # THE CROSS-PROCESS CRITICAL SECTION — see the module header for the
  # race this closes. Held across `cargo build` through the copy-out,
  # not just the copy: only THAT stretch, start to finish, is what
  # "safely rescue the shared `target/debug/rust` artifact before
  # another process's own build can overwrite it" actually requires.
  # `File::LOCK_EX` blocks the whole calling process until it gets the
  # lock — a second process's `cargo build` for a DIFFERENT feature
  # waits its turn rather than running concurrently with this one, which
  # is exactly the trade `PostgresEra#with_write_lock` already makes for
  # the identical reason (this module's header, and that method's own
  # comment). One lock file per `rust_dir`, created if it does not exist
  # yet — never removed, the same "leave the lock file on disk forever"
  # convention `flock(2)` itself expects.
  def build_and_pin(domain_feature, rust_dir)
    lock_path = File.join(rust_dir, "target", ".build_rust_for.lock")
    FileUtils.mkdir_p(File.dirname(lock_path))

    File.open(lock_path, File::CREAT | File::RDWR) do |lock|
      lock.flock(File::LOCK_EX)

      built = system("cargo", "build", "--no-default-features", "--features", domain_feature,
                     chdir: rust_dir, out: File::NULL, err: File::NULL)
      next nil unless built

      binary = File.join(rust_dir, "target", "debug", "rust")
      next nil unless File.executable?(binary)

      # `cargo build` always writes to this SAME path regardless of
      # which feature was requested — copy it out to a per-domain file
      # immediately, still inside the lock, so a concurrent process
      # from a DIFFERENT OS-level invocation can never observe (or
      # overwrite) this feature's binary mid-copy the way it could
      # before the lock existed.
      pinned = File.join(rust_dir, "target", "debug", "rust-#{domain_feature}")
      FileUtils.cp(binary, pinned)
      File.chmod(0o755, pinned)
      pinned
    end
  end

  # `corrects`'s own per-record flag fields (`emitted_<event>`, docs/
  # decisions/0049) are a Rust-only implementation detail riding along
  # with the generic snapshot mechanism — Ruby's own records never carry
  # them (its equivalent, `@registry.event_log`, lives on the REGISTRY,
  # never on a record's own `to_h`). They can surface on ANY comparison
  # surface a raw record reaches through — `instances`, but also
  # `queries` (a query answer embeds the same record shape) — so this
  # walks the whole Rust output recursively rather than special-casing
  # each surface one at a time, the same way `bin/rust_conformance`'s own
  # comment cites `spec/codegen_parity_spec.rb`'s precedent of excluding
  # generator/implementation artifacts from a check that exists to
  # verify BEHAVIOR, not internal representation.
  def strip_emitted_flags!(value)
    case value
    when Hash
      value.reject! { |k, _| k.start_with?("emitted_") }
      value.each_value { |v| strip_emitted_flags!(v) }
    when Array
      value.each { |v| strip_emitted_flags!(v) }
    end
    value
  end

  # `occurred_at` — a real event field on BOTH sides now (`kernel::Event`/
  # `Runtime::Event`, equivalence-gap plan item 2.5), but a wall clock,
  # never a comparable fact: Ruby's own comparison side (`Fuzzing::
  # Replay#call`, replay.rb) never even INCLUDES it in the projected
  # events this spec's own `ruby_events` is built from — two independent
  # process runs (this spec's own hand-authored fixtures carry no
  # `occurred_at` in their own `steps`, so rust/host's real stamping
  # mechanism never runs here at all) can't byte-match wall clocks
  # regardless. Stripped from Rust's own side only — the key `rust_output
  # ["events"]` now carries that `ruby_events` structurally never did —
  # the identical shape `strip_emitted_flags!`, just above, already
  # exists for: excluding a real, understood implementation/environment
  # detail from a check that exists to verify BEHAVIOR, not this.
  def strip_occurred_at!(value)
    case value
    when Hash
      value.reject! { |k, _| k == "occurred_at" }
      value.each_value { |v| strip_occurred_at!(v) }
    when Array
      value.each { |v| strip_occurred_at!(v) }
    end
    value
  end

  # See rust_conformance_spec.rb's own extensive comment on this exact
  # exclusion (a cross-domain policy match Ruby's single-process boot
  # delivers in-process but Rust's kernel genuinely cannot know the
  # outcome of yet) — reproduced verbatim, not re-derived, so both specs
  # agree on what a cross-domain reaction even means.
  def cross_domain_policy_names(rust_output)
    rust_output.fetch("cross_domain_reactions").flatten.to_set { |r| r["policy"] }
  end

  # RE-EXAMINED 2026-09-11 (ANGLE-4) AND FOUND STALE — REMOVED, not just
  # quieted, the same discipline model_check.rb's own ALLOWED_FINDINGS
  # comment already documents for its own removed entries. This used to
  # read:
  #
  #   reaction["policy"] == "FreezeAccountsOnSuspension" &&
  #     reaction["trigger"] == "Banking::Account.FreezeAccount" &&
  #     reaction["delivered"] == false
  #
  # — rust_conformance_spec.rb's own comment (above the fixture loop)
  # names the original gap: an argument-check-ordering difference (which
  # check runs first, unrecognized keys or identity-field absence) that
  # made Ruby's and Rust's refusal DIAGNOSIS differ for a malformed-
  # payload shape across three fixtures (entities_policies_sagas.json,
  # query_filters.json, named_queries_order_limit.json). Re-verified live
  # by forcing this predicate to `false` unconditionally and re-running
  # the full fixed corpus (`spec/rust_conformance_spec.rb --tag io`,
  # cargo binaries rebuilt fresh): all 30 fixtures, including the three
  # that used to need this exemption, pass with reactions matching
  # byte-for-byte — the ordering gap it was written for no longer
  # reproduces (closed by an unrelated fix somewhere in the argument-
  # gate/identity-check path since this predicate was last needed; not
  # tracked down further, since there is no longer a live divergence to
  # attribute). Kept as a named no-op (not deleted outright) so a call
  # site never breaks and the next real, narrow reaction-shaped gap has
  # an obvious place to be named by hand, the same as
  # `KNOWN_REFUSAL_GAP_VERBS`'s own empty-but-kept precedent just below.
  def known_reaction_gap?(_reaction)
    false
  end

  # THE FIXED CORPUS'S OWN NARROW LIST — found and named by hand against a
  # small, curated set of fixtures. Two entries used to live here, both
  # closed by Phase 10 (equivalence-gap plan) porting a declared `offset`
  # for real, in each case confirmed by re-running `bin/project_rust
  # examples/banking` and re-checking the exact same fixture RED-before/
  # GREEN-after: `Banking::ATMCard.ByFee` (a declared AGGREGATE query's own
  # `offset` — spec/corpus/rust_conformance/named_queries_order_limit.json)
  # and `Banking.ComplianceDashboard` (a declared READ MODEL's own
  # `offset` — spec/corpus/rust_conformance/read_models.json). Empty for
  # now — kept, not deleted, as the place the NEXT real, narrow, curated-
  # corpus gap gets named by hand, the same way these two were.
  KNOWN_REFUSAL_GAP_VERBS = [].freeze

  def known_refusal_gap?(entry)
    KNOWN_REFUSAL_GAP_VERBS.include?(entry.key?("verb") ? entry["verb"] : entry["query"])
  end

  # THE GENERALIZED FORM — PRD 04's own reason this can't just reuse
  # `known_refusal_gap?`'s fixed list: a RANDOMLY generated sequence can
  # reach any structurally-unsupported query/read-model verb the domain
  # declares, not only the two the fixed, hand-picked corpus happens to
  # exercise (`rust/project/queries.rb`'s and `read_models.rb`'s own
  # documented refusal boundary — offset/cursor/group_by/count/median/
  # cross-reference wheres, the whole Phase 10 backlog). Matched by
  # Rust's own EXACT refusal wording for this boundary
  # (`"is not generated for this domain"` — codegen's own literal string,
  # `rust/project/queries.rb`/`read_models.rb`), never by verb name: a
  # verb-name list would need to grow forever as the fuzzer explores
  # further; this message is the one honest signal codegen itself already
  # emits for "I cannot execute this construct at all," matching
  # rust_conformance_spec.rb's own "a named/declared query step whose
  # shape this generator doesn't cover still refuses cleanly" example
  # verbatim.
  STRUCTURAL_REFUSAL_MARKER = "is not generated for this domain".freeze

  def structural_refusal_gap?(entry)
    (entry["error"] || "").include?(STRUCTURAL_REFUSAL_MARKER)
  end

  # THE SAME BOUNDARY, SEEN FROM RUBY'S QUERY LOG — when Rust refuses a
  # named query as "not generated", Ruby answered it for real and logged
  # an ordinary (error-free) query entry, so `structural_refusal_gap?`
  # never matches it. Rust's own structural refusals are the ground truth
  # for which verbs to drop, the same way `cross_domain_policy_names`
  # reads Rust's own `cross_domain_reactions` rather than re-deriving.
  # THE WIRE FORMAT'S OWN LOSS, NOT A BEHAVIORAL DIVERGENCE. `Json::Num`
  # (rust/src/kernel/json.rs) is a plain `f64` end to end — every integer
  # this kernel's own JSON parser reads, including a query's own echoed
  # `args`, goes through it. An integer outside `f64`'s 53-bit exact
  # range (found live: a generated query `ceiling`/`floor` around
  # `1.27e30`) survives Ruby's own JSON round-trip exactly but is
  # ALREADY rounded the moment Rust's JSON parser reads the wire bytes
  # this fuzz bridge hands it — before any query-argument typing runs.
  # Normalizing both sides to the SAME `f64` rounding before comparing
  # says exactly that: once the wire format's own precision is
  # accounted for, the two engines agree. It is not applied to anything
  # this bridge treats as a refusal wording (those compare by KIND,
  # C8.2) — only to a query's own echoed `args`/`reference_rows`, which
  # this bridge compares by value.
  def reduce_to_wire_precision(value)
    case value
    when Integer then value.abs < (1 << 53) ? value : value.to_f
    when Hash    then value.transform_values { |v| reduce_to_wire_precision(v) }
    when Array   then value.map { |v| reduce_to_wire_precision(v) }
    else value
    end
  end

  def structurally_refused_verbs(rust_output)
    rust_output.fetch("refusals").select { |r| structural_refusal_gap?(r) }.to_set { |r| r["verb"] }
  end
end
