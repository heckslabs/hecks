require "json"
require "open3"
require "hecks/fuzzing"
require_relative "support/rust_conformance_helpers"

# THE RUST DIFFERENTIAL HARNESS, WIRED IN — bin/rust_conformance's own
# header comment used to say plainly that nothing did this ("this tool
# does not invoke Rust itself... until then, 'give me a JSON file to
# compare against' is the whole interface"). 0012 gave it a `native` mode
# that actually runs a compiled artifact; this is that mode, run as part
# of the same `bundle exec rspec` both `.githooks/pre-push` and CI already
# require — no separate CI step needed beyond building the binary first
# (`.github/workflows/ci.yml`), the same "provision it for real, don't
# skip" discipline that workflow already holds Postgres/SQLite to.
#
# Compares `instances`, `events`, `queries`, AND full refusal wording
# (`verb` + `error`, not just `verb`) — the two gaps that used to make
# exact `events`/wording comparison the wrong bar here are both closed
# now (0021): `Event.payload` used to be the router's raw, unfiltered args
# (0013's own `stamp_payload`) with no post-coercion default-fill —
# `Json::overlay` (json.rs) now merges the raw args with the typed args
# struct's OWN `to_json()`, matching Ruby's own coerced-hash payload; and
# `GivenNotMet`/`EnsuresNotMet` refusal wording now carries the same
# `"{command} refused — {description}"` prefix Ruby's own
# `CommandRules::Admissibility` raises with. Fixtures with no "query" step
# at all (every fixture below except query_filters.json) trivially pass
# the `queries` comparison — both engines report an empty array — so
# adding it here costs those fixtures nothing.
#
# THE REFUSAL-WORDING GAP THIS FILE USED TO NAME IS CLOSED. Fixtures used
# to be picked/maintained specifically to stay CLEAR of `LifecycleRefused`'s
# `transition_blocked`, the general VO-`invariant` message, `one_of`
# closed-set membership, and entity-element-missing — `rust/project.rb`'s
# own header used to name these as a real, separate, deliberately
# out-of-scope gap. `bin/project_refusal_wording` (generating `rust/src/
# kernel/refusal_wording.rs`, `RefusalSite`) closed all four, plus
# `record_missing` via `Hydrate::Act` (found live, previously unnamed) and
# a wrong REFUSAL CLASS on `closed_set_member` (`TypeMismatch`, not
# `InvariantViolation` — a behavioral bug, not just wording). The general
# VO-invariant message is no longer a gap at all: it was promoted into
# `RefusalWording::TEMPLATES`/`Vocabulary::RefusalTemplate` on the RUBY
# side too, so both engines render it off one declared template.
# `spec/corpus/rust_conformance/refusal_wording_*.json` — one fixture per
# site, below — is the proof: each was run against UNMODIFIED Rust first
# to confirm the mismatch was real, then again after the fix, both
# recorded in each fixture's own `note`.
#
# `io: true` — a real `cargo build` per fixture's own domain feature,
# same as every other spec that does real, uncontrolled I/O; excluded
# locally by default (spec_helper.rb), always run in CI.
RSpec.describe "Rust conformance (native binary)", :io do
  include RustConformanceHelpers

  RUST_CONFORMANCE_FIXTURES = Dir.glob(File.join(InMemoryDomain::ROOT, "spec/corpus/rust_conformance/*.json"))
  RUST_DIR = File.join(InMemoryDomain::ROOT, "rust")

  # `RustConformanceHelpers#build_rust_for` now takes `rust_dir` explicitly
  # (shared with spec/rust_conformance_fuzz_spec.rb, PRD 04) — this
  # wrapper keeps every call site below unchanged.
  def build_rust_for(domain_feature) = super(domain_feature, RUST_DIR)

  # `reactions`/`sagas` (`Registry#reaction_log`/`#saga_log`,
  # orchestrate.rs's own header) join the compared fields below, with TWO
  # documented, cited exclusions on Ruby's OWN side rather than a
  # weakened comparison on Rust's — both filters strip only the SPECIFIC
  # divergent record, by its own stable identifying fields, not a whole
  # fixture's worth of otherwise-real comparisons:
  #
  #   1. A CROSS-DOMAIN policy match. Ruby's single-process boot has no
  #      Lambda boundary at all, so `PolicyInterpreter#deliver` attempts
  #      delivery in-process regardless of `target_domain` and logs
  #      SOMETHING (found live: `entities_policies_sagas.json`'s own
  #      `ReviewOnFreeze` → "Compliance::Compliance.OpenReview", refused
  #      with `no domain "Compliance" loaded` — Compliance was never
  #      `uses_framework`'d into banking's own test boot). Rust's kernel
  #      genuinely cannot know a cross-domain match's delivery outcome —
  #      that only exists once rust/host's `lambda_client.rs` finishes
  #      the call, and it doesn't build a reaction_log entry either yet
  #      (orchestrate.rs's own header, and rust/project.rb's). Filtered
  #      out here using RUST's own `cross_domain_reactions` output as the
  #      ground truth for which policy names it declined to log, rather
  #      than re-deriving cross-domain-ness on the Ruby side.
  #
  #   2. `FreezeAccountsOnSuspension` forwards `CustomerSuspended`'s
  #      payload (no `number:` field at all) into `Account.FreezeAccount` —
  #      found live, across THREE fixtures that all happen to dispatch
  #      `Customer.Suspend` (entities_policies_sagas.json, query_filters.
  #      json, named_queries_order_limit.json — none of them chosen for
  #      this reason, all three just incidentally exercise it), to refuse
  #      on BOTH sides but with genuinely different diagnoses: Ruby's
  #      `ArgumentGate` reaches an (already-broken, pre-existing,
  #      unrelated-to-Rust) truncated "does not declare standing — it
  #      takes " message; Rust's generated `from_json` reaches "no
  #      identity found" instead — a real, narrow ARGUMENT-CHECK-
  #      ORDERING gap (which check runs first: unrecognized keys, or
  #      identity-field absence) for a malformed-payload shape no corpus
  #      fixture exercised before `reactions` was ever compared. Matched
  #      by `policy`+`trigger`+`delivered: false` (an unambiguous
  #      signature — this exact pairing only ever means this one gap),
  #      not by fixture name, so a FUTURE fixture that happens to hit the
  #      same case is covered by the same rule instead of silently
  #      becoming a mismatched test.
  #
  # `cross_domain_policy_names`/`known_reaction_gap?` are
  # `RustConformanceHelpers` methods now (shared with
  # spec/rust_conformance_fuzz_spec.rb, PRD 04) — this comment describes
  # both, kept here since this is where each gap was first found.

  # THE READ_MODEL/QUERY-CODEGEN BOUNDARY'S OWN REFUSAL, one level up
  # from the single-step example below — the SAME gap
  # (rust/project/read_models.rb's and queries.rb's own headers, and
  # bin/rust_coverage's "KNOWN RED, ON PURPOSE" citation for banking),
  # reached here as an incidental step inside a fixture built for
  # something else entirely (read_models.json for read models in
  # general, named_queries_order_limit.json for order_by/limit). BOTH
  # sides genuinely refuse this verb — Ruby executes the construct for
  # real and hits its own, ordinary business refusal
  # (`Banking.ComplianceDashboard`'s "no Account with reference ..." —
  # ComplianceDashboard's own real answer for *this* fixture's data);
  # Rust can't execute the construct at all yet and refuses "is not
  # generated for this domain" instead. Matched by VERB, not exact
  # wording — the two sides are never claimed to refuse for the SAME
  # reason, only that refusing here, on both sides, is expected and not
  # a byte-for-byte comparison this generator's own documented boundary
  # can pass.
  # `queries` carries the SAME gap under a DIFFERENT key — Ruby logs a
  # query-log entry for these (`"query" => "Banking.ComplianceDashboard"`,
  # its own refusal payload inline) even though the ask refused, since
  # Ruby genuinely executed it; Rust never attempted the query at all, so
  # its own queries log simply has no matching entry — exempted the same
  # way, checking either key a step's own log entry uses.
  #
  # `KNOWN_REFUSAL_GAP_VERBS`/`known_refusal_gap?` are
  # `RustConformanceHelpers` constants/methods now — this fixed corpus's
  # own narrow, hand-verified list, unchanged. PRD 04's generated-sequence
  # bridge (spec/rust_conformance_fuzz_spec.rb) uses a DIFFERENT,
  # message-pattern-based version of this same judgment instead
  # (`structural_refusal_gap?`) — see that helper's own comment for why a
  # fixed verb list doesn't scale to a randomly generated sequence.

  RUST_CONFORMANCE_FIXTURES.each do |fixture_path|
    # A real cargo-built binary compared field-by-field (instances,
    # events, refusals, queries, sagas, dry_runs, reactions) against one
    # fixture's own replay — one coherent byte-for-byte conformance
    # proof per fixture; splitting per field would re-pay the cargo
    # build and the subprocess spawn for no real gain.
    # rubocop:disable-next RSpec/ExampleLength
    it "#{File.basename(fixture_path)}: instances, events, refusals, reactions, and sagas match Ruby exactly" do
      fixture = JSON.parse(File.read(fixture_path))
      domain  = fixture.fetch("domain")
      steps   = fixture.fetch("steps")

      binary = build_rust_for(File.basename(domain).downcase)
      skip "rust/Cargo.toml has no #{File.basename(domain).downcase} feature — run bin/project_rust for it first" unless binary

      ruby_result = Hecks::Fuzzing::Replay.call(domain, steps)
      ruby_instances = ruby_result[:instances].transform_values { |state| JSON.parse(JSON.generate(state)) }
      ruby_events = JSON.parse(JSON.generate(ruby_result[:events]))
      ruby_refusals = ruby_result[:refusals].map { |r| { "verb" => r[:verb].to_s, "error" => r[:error] } }
      # `instances_at:` — Fuzzing::Replay's OWN per-query snapshot for the
      # property harness (Properties.group_by_matches_recompute and
      # siblings), never part of the "queries" contract this spec holds
      # Rust to; Rust's own compiled binary has no equivalent field at
      # all, so it's stripped here rather than becoming a permanent,
      # meaningless diff.
      ruby_queries = JSON.parse(JSON.generate(ruby_result[:queries].map { |q| q.except(:instances_at) }))
      ruby_sagas = JSON.parse(JSON.generate(ruby_result[:sagas]))

      stdout, status = Open3.capture2(binary, stdin_data: JSON.generate({ "steps" => steps }))
      expect(status).to be_success, "#{binary} exited #{status.exitstatus}:\n#{stdout}"

      rust_output = JSON.parse(stdout)
      strip_emitted_flags!(rust_output["instances"])
      strip_emitted_flags!(rust_output["queries"])
      strip_occurred_at!(rust_output["events"])

      expect(rust_output["instances"]).to eq(ruby_instances)
      expect(rust_output["events"]).to eq(ruby_events)
      expect(rust_output["refusals"].reject { |r| known_refusal_gap?(r) })
        .to eq(ruby_refusals.reject { |r| known_refusal_gap?(r) })
      expect(rust_output["queries"].reject { |q| known_refusal_gap?(q) })
        .to eq(ruby_queries.reject { |q| known_refusal_gap?(q) })
      expect(rust_output["sagas"]).to eq(ruby_sagas)
      expect(rust_output["dry_runs"]).to eq(JSON.parse(JSON.generate(ruby_result[:dry_runs])))

      cross_domain = cross_domain_policy_names(rust_output)
      ruby_reactions = JSON.parse(JSON.generate(ruby_result[:reactions]))
                           .reject { |r| cross_domain.include?(r["policy"]) || known_reaction_gap?(r) }
      rust_reactions = rust_output.fetch("reactions").reject { |r| known_reaction_gap?(r) }
      expect(rust_reactions).to eq(ruby_reactions)
    end
  end

  # THE OTHER "query" STEP SHAPE'S OWN REMAINING BOUNDARY — a NAMED/declared
  # bluebook ask (the STRING form) whose OWN shape this generator's query
  # codegen doesn't cover. Used to be `Banking::Account.Open` (it declared
  # `order_by`, which disqualified it outright) — that closed 2026-08-11,
  # the moment `kernel/query_ordering.rs` gave `named_query.rs` the same
  # sort/limit tail `read_model.rs` already had (see named_queries_order_
  # limit.json for `Account.Open` now genuinely executing, byte-for-byte
  # against Ruby). `Banking::Account.OpenForSuspendedCustomers` takes its
  # place here — it hops through a reference (`where(:"customer.status" =>
  # "suspended")`, checked on Customer, not Account's own declared fields),
  # a genuinely different and still-real gap `rust/project/queries.rb`'s
  # own header names as read_model territory, not something order_by/limit
  # support touches at all. Ruby answers this one for real (`Fuzzing::
  # Replay` dispatches it through `runtime.query`) but this compiled binary
  # still, deliberately, does not. NOT a byte-for-byte parity check against
  # Ruby — there is nothing to be "in conformance" with here, Ruby doesn't
  # refuse this at all — this instead proves the boundary itself is
  # HONEST: a clean `Refusal::TypeMismatch`, valid JSON, exit 0, never a
  # panic or a wrong-but-silent answer, even though a real named query
  # (query_filters.json's own CardPayment.Pending/Disputed/Flagged,
  # ExternalTransfer.Sent, Governance's/Identity's, and now every order_by/
  # limit-bearing declared query in named_queries_order_limit.json) now
  # genuinely executes right alongside it in the very same binary.
  it "a named/declared query step whose shape this generator doesn't cover still refuses cleanly (not a " \
     "byte-for-byte comparison — Ruby answers this one for real)" do
    binary = build_rust_for("banking")
    skip "rust/Cargo.toml has no banking feature — run bin/project_rust for it first" unless binary

    stdout, status = Open3.capture2(
      binary,
      stdin_data: JSON.generate({ "steps" => [{ "query" => "Banking::Account.OpenForSuspendedCustomers" }] })
    )
    expect(status).to be_success, "#{binary} exited #{status.exitstatus}:\n#{stdout}"

    rust_output = JSON.parse(stdout)
    expect(rust_output["refusals"].size).to eq(1)
    expect(rust_output["refusals"][0]["verb"]).to eq("Banking::Account.OpenForSuspendedCustomers")
    expect(rust_output["refusals"][0]["error"])
      .to include("Banking::Account.OpenForSuspendedCustomers")
      .and include("is not generated for this domain")
    expect(rust_output["queries"]).to eq([])
  end
end
