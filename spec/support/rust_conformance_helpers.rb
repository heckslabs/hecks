# Shared between spec/rust_conformance_spec.rb (the fixed, hand-authored
# corpus) and spec/rust_conformance_fuzz_spec.rb (PRD 04 — the same
# differential check, run against SequenceGenerator's own randomly
# generated sequences instead). Factored out so the two never drift on
# what "a known, understood boundary, not a bug" means — that judgment is
# real, cited, and earned per case (see rust_conformance_spec.rb's own
# extensive comments on each), and belongs in exactly one place.
#
# `@build_cache`'s own header (below) already explains why one process
# building `--features X` then `--features Y` back to back is unsafe —
# `bin/qa_sweep --all` (see that script's own header on why) is what made
# a second, worse version of the same problem real: several
# `bin/qa_sweep <target>` invocations, each its own OS process with its
# own empty `@build_cache`, now genuinely run `cargo build --features X`
# and `cargo build --features Y` at the same time rather than back to
# back. `cargo build` itself is safe under that — it holds its own lock
# over `target/` and simply serializes the two real compiles — but this
# method's own critical section is not: `system("cargo build", ...)`
# always writes to the same shared `target/debug/rust` path no matter
# which feature was requested, and only this method's own next two lines
# (`FileUtils.cp` to the per-feature pinned path) rescue that shared
# artifact before it can be overwritten again. Between one process's
# `system` call returning and its own `FileUtils.cp` running is exactly
# the window a second process's `cargo build` for a different feature
# could finish in and overwrite `target/debug/rust` out from under
# it — pinning the second process's binary under the first process's own
# feature's name, and letting a differential fuzz run silently diff
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
require "open3"
require_relative "../../lib/hecks/fuzzing/nondeterministic"

# Shared differential-testing helpers for the Ruby/Rust conformance specs: builds (and
# process-wide caches) each domain's Rust binary, and normalizes both engines' output before
# comparing it.
module RustConformanceHelpers
  # A declared feature that did not build — raised, never answered as nil.
  # `build_rust_for` answers nil for exactly one reason (the crate declares
  # no such feature, so the caller's own named skip applies); a failed
  # `cargo build` would otherwise read as that same nil and silently become a skip.
  # The message carries cargo's own stderr.
  class BuildFailed < StandardError; end

  # Process-wide, keyed on [rust_dir, domain_feature] — not per-example
  # and not per-file. `spec_helper.rb`'s `config.order = :random`
  # interleaves examples from every file in a single `rspec` process, so
  # without this, a run touching rust_conformance_spec.rb's 22 fixtures
  # (20 banking, 1 pizzas, 1 roster) plus rust_conformance_fuzz_spec.rb's
  # 2 domains could interleave `--features banking` and `--features
  # pizzas` calls in effectively any order. `cargo build --features X`
  # immediately after a `--features Y` build forces a real recompile of
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

  # Built for this fixture/sequence's own domain — but only the first
  # time a given (rust_dir, domain_feature) pair is requested; every
  # later call for the same pair returns the memoized result with no
  # cargo invocation at all. See the module-level comment above for why
  # this replaced "never found by trusting whatever happens to already
  # sit at rust/target/{release,debug}/rust" — that discipline is still
  # honored (nothing here trusts an ambient binary left over from a
  # previous rspec run or another process), it's just no longer re-paid
  # on every single call within this one.
  #
  # Answers nil only when Cargo.toml declares no such feature. A declared
  # feature that fails to build raises `BuildFailed` (cargo's stderr in the
  # message) — memoized like a success, so every later request for the same
  # pair re-raises the same failure instead of re-paying a doomed build.
  #
  # @param domain_feature [String] the cargo feature to build, such as `"banking"`
  # @param rust_dir [String] absolute path to the Rust crate directory to build in
  # @return [String, nil] absolute path to the pinned per-feature binary, or `nil` if
  #   Cargo.toml declares no such feature
  # @raise [RustConformanceHelpers::BuildFailed] if the build failed (fresh, or replayed from
  #   the memoized failure of an earlier call for the same pair)
  def build_rust_for(domain_feature, rust_dir)
    cache = RustConformanceHelpers.build_cache
    cache_key = [rust_dir, domain_feature]
    if cache.key?(cache_key)
      raise cache[cache_key] if cache[cache_key].is_a?(BuildFailed)

      return cache[cache_key]
    end

    cargo_toml = File.read(File.join(rust_dir, "Cargo.toml"))
    return cache[cache_key] = nil unless cargo_toml =~ /^#{Regexp.escape(domain_feature)}\s*=\s*\[\]/

    begin
      cache[cache_key] = build_and_pin(domain_feature, rust_dir)
    rescue BuildFailed => e
      cache[cache_key] = e
      raise
    end
  end

  # The cross-process critical section — see the module header for the
  # race this closes. Held across `cargo build` through the copy-out,
  # not just the copy: only that stretch, start to finish, is what
  # "safely rescue the shared `target/debug/rust` artifact before
  # another process's own build can overwrite it" actually requires.
  # `File::LOCK_EX` blocks the whole calling process until it gets the
  # lock — a second process's `cargo build` for a different feature
  # waits its turn rather than running concurrently with this one, which
  # is exactly the trade `PostgresEra#with_write_lock` already makes for
  # the identical reason (this module's header, and that method's own
  # comment). One lock file per `rust_dir`, created if it does not exist
  # yet — never removed, the same "leave the lock file on disk forever"
  # convention `flock(2)` itself expects.
  #
  # @param domain_feature [String] the cargo feature to build, passed to `--features`
  # @param rust_dir [String] absolute path to the Rust crate directory to build in
  # @return [String] absolute path to the freshly built, per-feature-pinned executable
  # @raise [RustConformanceHelpers::BuildFailed] if the `cargo build` subprocess cannot run,
  #   exits non-zero, or leaves no executable behind
  def build_and_pin(domain_feature, rust_dir)
    lock_path = File.join(rust_dir, "target", ".build_rust_for.lock")
    FileUtils.mkdir_p(File.dirname(lock_path))

    File.open(lock_path, File::CREAT | File::RDWR) do |lock|
      lock.flock(File::LOCK_EX)

      command = ["cargo", "build", "--no-default-features", "--features", domain_feature]
      begin
        _stdout, stderr, status = Open3.capture3(*command, chdir: rust_dir)
      rescue SystemCallError => e
        raise BuildFailed, "`#{command.join(' ')}` could not run in #{rust_dir}: #{e.message}"
      end
      unless status.success?
        raise BuildFailed, "`#{command.join(' ')}` failed in #{rust_dir} (exit #{status.exitstatus}) — " \
                           "#{domain_feature} is declared in Cargo.toml, so this is a build failure, " \
                           "not a missing feature:\n#{stderr}"
      end

      binary = File.join(rust_dir, "target", "debug", "rust")
      unless File.executable?(binary)
        raise BuildFailed, "`#{command.join(' ')}` succeeded in #{rust_dir} but left no executable at #{binary}:\n#{stderr}"
      end

      # `cargo build` always writes to this same path regardless of
      # which feature was requested — copy it out to a per-domain file
      # immediately, still inside the lock, so a concurrent process
      # from a different OS-level invocation can never observe (or
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
  # them (its equivalent, `@registry.event_log`, lives on the registry,
  # never on a record's own `to_h`). They can surface on any comparison
  # surface a raw record reaches through — `instances`, but also
  # `queries` (a query answer embeds the same record shape) — so this
  # walks the whole Rust output recursively rather than special-casing
  # each surface one at a time, the same way `bin/rust_conformance`'s own
  # comment cites `spec/codegen_parity_spec.rb`'s precedent of excluding
  # generator/implementation artifacts from a check that exists to
  # verify behavior, not internal representation.
  #
  # @param value [Object] a Rust JSON-decoded value (Hash, Array, or scalar) to strip
  # @return [Object] `value`, with every `"emitted_"`-prefixed Hash key removed from it and
  #   its nested values
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

  # `Hecks::Fuzzing::Nondeterministic`'s `event` group (`occurred_at`, a
  # wall clock — its reason is declared there), string-keyed as the Rust
  # binary's JSON carries it. Ruby's own comparison side (`Fuzzing::
  # Replay#call`) never includes it in the projected events `ruby_events`
  # is built from, so it is stripped from Rust's own side only, recursively.
  NONDETERMINISTIC_EVENT_KEYS = Hecks::Fuzzing::Nondeterministic.names(:event).map(&:to_s).freeze

  # Strips every nondeterministic wall-clock field from Rust's own JSON output, recursively.
  #
  # @param value [Object] a Rust JSON-decoded value (Hash, Array, or scalar) to strip
  # @return [Object] `value`, with every key in `NONDETERMINISTIC_EVENT_KEYS` removed from it
  #   and its nested values
  def strip_occurred_at!(value)
    case value
    when Hash
      value.reject! { |k, _| NONDETERMINISTIC_EVENT_KEYS.include?(k) }
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
  #
  # @param rust_output [Hash] the Rust binary's own decoded JSON output for one fuzz run
  # @return [Set<String>] the policy names in `rust_output["cross_domain_reactions"]`,
  #   deduplicated
  def cross_domain_policy_names(rust_output)
    rust_output.fetch("cross_domain_reactions").flatten.to_set { |r| r["policy"] }
  end

  # Which refusals may differ is no longer decided here. The hand-kept
  # `KNOWN_REFUSAL_GAP_VERBS` list (empty), the always-false
  # `known_reaction_gap?`, and the "is not generated for this domain"
  # substring match are gone: a query or read-model verb is tolerated only
  # when the binary's own manifest.json declares it `generated: false`
  # (`Hecks::Fuzzing::RustGapManifest`, applied by `Hecks::Fuzzing::
  # Differential.manifest_partition`).

  # The wire format's own loss, not a behavioral divergence. `Json::Num`
  # (rust/src/kernel/json.rs) is a plain `f64` end to end — every integer
  # this kernel's own JSON parser reads, including a query's own echoed
  # `args`, goes through it. An integer outside `f64`'s 53-bit exact
  # range (found live: a generated query `ceiling`/`floor` around
  # `1.27e30`) survives Ruby's own JSON round-trip exactly but is
  # already rounded the moment Rust's JSON parser reads the wire bytes
  # this fuzz bridge hands it — before any query-argument typing runs.
  # Normalizing both sides to the same `f64` rounding before comparing
  # says exactly that: once the wire format's own precision is
  # accounted for, the two engines agree. It is not applied to anything
  # this bridge treats as a refusal wording (those compare by kind,
  # C8.2) — only to a query's own echoed `args`/`reference_rows`, which
  # this bridge compares by value.
  #
  # @param value [Object] a value from either engine's comparison output — an Integer, Hash,
  #   Array, or other scalar
  # @return [Object] `value`, with every Integer outside `f64`'s 53-bit exact range converted
  #   to a Float, recursively through Hashes and Arrays
  def reduce_to_wire_precision(value)
    case value
    when Integer then value.abs < (1 << 53) ? value : value.to_f
    when Hash    then value.transform_values { |v| reduce_to_wire_precision(v) }
    when Array   then value.map { |v| reduce_to_wire_precision(v) }
    else value
    end
  end
end
