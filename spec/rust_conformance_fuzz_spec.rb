require "json"
require "open3"
require "hecks/fuzzing"
require_relative "support/rust_conformance_helpers"

# PRD 04 (rust-conformance-fuzzing) — spec/rust_conformance_spec.rb only
# ever compares Ruby vs. Rust over a FIXED, hand-authored corpus.
# `Hecks::Fuzzing::SequenceGenerator`'s randomly generated sequences never
# reached it before this file — meaning the single highest-leverage check
# in the whole equivalence-gap plan (per its own text: "it would have
# caught most of today's [nine] bugs automatically instead of needing
# manual investigation") didn't exist yet. This is that bridge: generate
# N seeded sequences per domain, run each through BOTH `Replay.call` and
# the compiled Rust conformance binary, diff the same way
# rust_conformance_spec.rb already does (shared helpers, not re-derived —
# see support/rust_conformance_helpers.rb).
#
# `bin/fuzz`'s own header used to say this comparison "no longer exists"
# (true the first time Rust was retired — docs/implemented/
# rust-experiment.md — stale the moment Rust came back, 2026-08-07; fixed
# alongside this file, see that script's own updated header).
#
# `io: true` — a real `cargo build` per domain feature, same as
# rust_conformance_spec.rb; excluded locally by default, always run in
# CI. Deliberately its OWN file rather than folded into
# rust_conformance_spec.rb: that file's job is proving byte-for-byte
# agreement on a small, fully-understood, hand-curated corpus; this file's
# job is FINDING divergences an unbounded input space could still be
# hiding — different intent, kept visually and organizationally separate.
#
# STAGE 10 (docs/semantics/bluebook-semantics.md) closed most of what
# blocked this bridge: refusals compare by KIND, not prose (C8.2), and
# ADR 0037's findings 3 and 4 are closed in both generators, along with
# three more the un-pended run turned up (its status addendum has the
# full list). Finding 7 — an earlier-declared argument's invariant
# failure and a later-declared argument's shape failure, on the same
# command, used to refuse in different orders on the two runtimes — is
# CLOSED too, in both generators (`rust/project/json_codec.rb#emit_
# from_json_flat`/`rust/codegen/src/json_codec.rs`'s own `interleave_
# checks`): every command/entity-command/port-operation Args struct now
# builds one declared attribute's shape, THEN that same attribute's own
# admits-constraint-plus-invariant pair, before moving to the next
# attribute, matching Ruby's own `coerce_declared_arguments` exactly.
# Finding 5 (`resolve_state_references` never ported — see ADR 0037's
# own updated status) turned out to already be moot: the bluebook
# redeclaration its root cause depended on (`SafeDepositBox.Rent`'s own
# `attribute :customer, CustomerNumber`) was removed by unrelated work
# (PR #409, 2026-08-28) before this was ever re-verified live — `sets
# :customer` now bridges straight to the aggregate's own `Reference
# <Customer>` type, so the ALREADY-PORTED command-level `resolve_
# references` check (`rust/project/domain_generator.rb#reference_
# checks`) catches the dangling-reference case on both engines today,
# confirmed against the real compiled binary, not just re-read source.
RSpec.describe "Rust conformance, over generated sequences (native binary)", :io do
  include RustConformanceHelpers

  FUZZ_RUST_DIR = File.join(InMemoryDomain::ROOT, "rust")

  # EVERY DOMAIN WITH A CARGO FEATURE OF ITS OWN — this used to be
  # pizzas/banking only (ANGLE-3: compliance/roster/chess and the three
  # stress domains all had compiled binaries and were never wired in
  # here, so BUG#13's class — an engine-divergence Ruby-only fuzzing
  # structurally cannot see — was gated in CI on two domains out of
  # eight). `entity_list_mutations` is still not included: it has no
  # Cargo feature at all (never regenerated into `rust/src/generated/`),
  # so there is no binary to compare against; `meta`/`embryonaut` have
  # their own conformance specs and are not sweep targets.
  # `SEEDS_PER_DOMAIN` is deliberately modest (an `io: true` spec already
  # pays a full `cargo build` per domain; each seed here ALSO pays a
  # subprocess spawn) — widen it locally with `SEEDS=40 bundle exec rspec
  # spec/rust_conformance_fuzz_spec.rb --tag io` when hunting, same
  # convention `bin/fuzz` itself uses for its own seed count.
  DOMAINS = %w[
    examples/pizzas examples/banking examples/chess examples/compliance examples/roster
    qa/stress_domains/waybill qa/stress_domains/nested_pieces qa/stress_domains/ledger_ordering
  ].map { |path| File.join(InMemoryDomain::ROOT, path) }.freeze
  SEEDS_PER_DOMAIN = Integer(ENV["SEEDS"] || 10)
  STEPS_PER_SEQUENCE = 25
  # OPT-IN, OFF IN CI — `SequenceGenerator`'s adversarial layer
  # (sequence_generator/adversary.rb) is what `bin/qa_sweep` runs by
  # default; here it stays at 0 so this gate keeps pinning exactly the
  # sequences it always has. `ADVERSARIAL=0.3 bundle exec rspec
  # spec/rust_conformance_fuzz_spec.rb --tag io` turns it on locally
  # when hunting, the same way `SEEDS=` already widens the pass.
  ADVERSARIAL_FRACTION = Float(ENV["ADVERSARIAL"] || 0)

  def build_rust_for(domain_feature) = super(domain_feature, FUZZ_RUST_DIR)

  DOMAINS.each do |domain|
    describe File.basename(domain) do
      # A real cargo-built binary compared field-by-field (instances,
      # events, refusals, queries, sagas, reactions) across every
      # generated seed, accumulating one combined divergence report —
      # splitting per field or per seed would re-pay the cargo build and
      # subprocess spawns, and would scatter one seed's related
      # divergences across separate failures instead of one readable report.
      # Both examples GATE now — ADR 0037's own catalogue (findings 3, 4,
      # 5, 6, 7) is fully closed; no `pending:` left on either domain.

      # rubocop:disable-next RSpec/ExampleLength
      it "agrees with Ruby across #{SEEDS_PER_DOMAIN} generated sequences (instances, events, refusals, " \
         "reactions, sagas, queries)" do
        feature = File.basename(domain).downcase
        binary = build_rust_for(feature)
        skip "rust/Cargo.toml has no #{feature} feature — run bin/project_rust for it first" unless binary

        divergences = []

        (1..SEEDS_PER_DOMAIN).each do |seed|
          steps = Hecks::Fuzzing::SequenceGenerator.generate(domain, seed: seed, steps: STEPS_PER_SEQUENCE,
                                                                        adversarial: ADVERSARIAL_FRACTION)

          ruby_result = Hecks::Fuzzing::Replay.call(domain, steps)
          ruby_instances = JSON.parse(JSON.generate(ruby_result[:instances]))
          ruby_events    = JSON.parse(JSON.generate(ruby_result[:events]))
          # REFUSALS ARE COMPARED BY KIND, NOT WORDING (C8.2, docs/semantics/
          # bluebook-semantics.md: prose is not the contract) — the same
          # rule spec/semantics_corpus_spec.rb holds both kernels to. The
          # message still rides along until the gap filters (which match
          # on Rust's own structural wording) have run, then drops.
          ruby_refusals  = ruby_result[:refusals].map do |r|
            { "verb" => r[:verb].to_s, "kind" => r[:kind].to_s.split("::").last, "error" => r[:error] }
          end
          ruby_queries   = JSON.parse(JSON.generate(ruby_result[:queries].map { |q| q.except(:instances_at) }))
          ruby_sagas     = JSON.parse(JSON.generate(ruby_result[:sagas]))

          stdout, status = Open3.capture2(binary, stdin_data: JSON.generate({ "steps" => steps }))
          unless status.success?
            divergences << { seed: seed, field: "process", detail: "exited #{status.exitstatus}: #{stdout}" }
            next
          end

          rust_output = JSON.parse(stdout)
          strip_emitted_flags!(rust_output["instances"])
          strip_emitted_flags!(rust_output["queries"])
          strip_occurred_at!(rust_output["events"])

          if rust_output["instances"] != ruby_instances
            divergences << { seed: seed, field: "instances",
                              ruby: ruby_instances, rust: rust_output["instances"] }
          end
          if rust_output["events"] != ruby_events
            divergences << { seed: seed, field: "events",
                              ruby: ruby_events, rust: rust_output["events"] }
          end

          by_kind = ->(r) { r.slice("verb", "kind") }
          rust_refusals = rust_output["refusals"].reject { |r| known_refusal_gap?(r) || structural_refusal_gap?(r) }
                                                 .map(&by_kind)
          kept_ruby_refusals = ruby_refusals.reject { |r| known_refusal_gap?(r) || structural_refusal_gap?(r) }
                                            .map(&by_kind)
          if rust_refusals != kept_ruby_refusals
            divergences << { seed: seed, field: "refusals",
                              ruby: kept_ruby_refusals, rust: rust_refusals }
          end

          wordless = ->(q) { reduce_to_wire_precision(q.except("error", "reference_error")) }
          not_generated = structurally_refused_verbs(rust_output)
          rust_queries = rust_output["queries"].reject { |q| known_refusal_gap?(q) || structural_refusal_gap?(q) }
                                               .map(&wordless)
          kept_ruby_queries = ruby_queries.reject do |q|
            known_refusal_gap?(q) || structural_refusal_gap?(q) || not_generated.include?(q["query"])
          end.map(&wordless)
          if rust_queries != kept_ruby_queries
            divergences << { seed: seed, field: "queries",
                              ruby: kept_ruby_queries, rust: rust_queries }
          end

          if rust_output["sagas"] != ruby_sagas
            divergences << { seed: seed, field: "sagas",
                              ruby: ruby_sagas, rust: rust_output["sagas"] }
          end

          cross_domain = cross_domain_policy_names(rust_output)
          kept_ruby_reactions = JSON.parse(JSON.generate(ruby_result[:reactions]))
                                    .reject { |r| cross_domain.include?(r["policy"]) || known_reaction_gap?(r) }
          rust_reactions = rust_output.fetch("reactions").reject { |r| known_reaction_gap?(r) }
          if rust_reactions != kept_ruby_reactions
            divergences << { seed: seed, field: "reactions",
                              ruby: kept_ruby_reactions, rust: rust_reactions }
          end
        end

        # A REAL DIVERGENCE HERE IS A FINDING, NOT JUST A FAILING SPEC —
        # per the plan's own text: shrink it with `bin/fuzz`'s existing
        # shrinker (`bin/fuzz shrink #{domain} <seed>` — see that script's
        # own header) before filing it, the same red-before/green-after
        # discipline this whole session held to. Printed here (not just
        # asserted false) so the seed and the exact field that split are
        # never buried in a diff too large to read.
        message = divergences.map do |d|
          "seed #{d[:seed]} — #{d[:field]}" +
            (d[:detail] ? ": #{d[:detail]}" : "\n  ruby: #{d[:ruby].inspect}\n  rust: #{d[:rust].inspect}")
        end.join("\n")

        expect(divergences).to be_empty, "#{divergences.size} divergence(s) found — reproduce with " \
                                         "`SEEDS=1 bundle exec rspec` after isolating the seed below, " \
                                         "then shrink with bin/fuzz:\n#{message}"
      end
    end
  end
end
