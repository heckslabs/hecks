require "json"
require "open3"
require "hecks/fuzzing"
require "hecks/fuzzing/differential"
require_relative "support/rust_conformance_helpers"

# PRD 04 (rust-conformance-fuzzing) — spec/rust_conformance_spec.rb only
# ever compares Ruby vs. Rust over a fixed, hand-authored corpus.
# `Hecks::Fuzzing::SequenceGenerator`'s randomly generated sequences never
# reached it before this file — meaning the single highest-leverage check
# in the whole equivalence-gap plan (per its own text: "it would have
# caught most of today's [nine] bugs automatically instead of needing
# manual investigation") didn't exist yet. This is that bridge: generate
# N seeded sequences per domain, run each through both `Replay.call` and
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
# CI. Deliberately its own file rather than folded into
# rust_conformance_spec.rb: that file's job is proving byte-for-byte
# agreement on a small, fully-understood, hand-curated corpus; this file's
# job is finding divergences an unbounded input space could still be
# hiding — different intent, kept visually and organizationally separate.
#
# Stage 10 (docs/semantics/bluebook-semantics.md) closed most of what
# blocked this bridge: refusals compare by kind, not prose (C8.2), and
# ADR 0037's findings 3 and 4 are closed in both generators, along with
# three more the un-pended run turned up (its status addendum has the
# full list). Finding 7 — an earlier-declared argument's invariant
# failure and a later-declared argument's shape failure, on the same
# command, used to refuse in different orders on the two runtimes — is
# closed too, in both generators (`rust/project/json_codec.rb#emit_
# from_json_flat`/`rust/codegen/src/json_codec.rs`'s own `interleave_
# checks`): every command/entity-command/port-operation Args struct now
# builds one declared attribute's shape, then that same attribute's own
# admits-constraint-plus-invariant pair, before moving to the next
# attribute, matching Ruby's own `coerce_declared_arguments` exactly.
# Finding 5 (`resolve_state_references` never ported — see ADR 0037's
# own updated status) turned out to already be moot: the bluebook
# redeclaration its root cause depended on (`SafeDepositBox.Rent`'s own
# `attribute :customer, CustomerNumber`) was removed by unrelated work
# (PR #409, 2026-08-28) before this was ever re-verified live — `sets
# :customer` now bridges straight to the aggregate's own `Reference
# <Customer>` type, so the already-ported command-level `resolve_
# references` check (`rust/project/domain_generator.rb#reference_
# checks`) catches the dangling-reference case on both engines today,
# confirmed against the real compiled binary, not just re-read source.
RSpec.describe "Rust conformance, over generated sequences (native binary)", :io do
  include RustConformanceHelpers

  FUZZ_RUST_DIR = File.join(InMemoryDomain::ROOT, "rust")

  # Every in-repo domain with a cargo feature of its own, derived —
  # `Hecks::Corpus.rust_domains`, the same list the codegen drift check
  # regenerates. This used to be a hand list of 8 while rust/Cargo.toml
  # had 20 features. The two features with no in-repo domain directory
  # (`meta`, `embryonaut`) go to the checks `Corpus::RUST_ELSEWHERE`
  # names, and spec/corpus_rust_spec.rb proves every feature lands in one
  # bucket or the other. A domain with no Cargo feature (e.g.
  # `generated_keyword_aggregate`, whose `Crate` aggregate is a Rust
  # keyword — PR #673's reserved-name check owns it) has no binary to
  # compare against.
  # `SEEDS_PER_DOMAIN` is deliberately modest (an `io: true` spec already
  # pays a full `cargo build` per domain; each seed here also pays a
  # subprocess spawn) — widen it locally with `SEEDS=40 bundle exec rspec
  # spec/rust_conformance_fuzz_spec.rb --tag io` when hunting, same
  # convention `bin/fuzz` itself uses for its own seed count.
  DOMAINS = Hecks::Corpus.rust_domains.map(&:dir).freeze

  # **Shrink-only**: a domain that still diverges, with the bug that owns it.
  # Its example runs as RSpec `pending`, so the day it agrees with Ruby
  # the example fails until the entry is deleted here.
  RUST_FUZZ_PENDING = {}.freeze

  # A total, spread across DOMAINS — not per domain. The hand list ran
  # 8 domains x 10 seeds = 80; deriving the list must not add gating
  # wall-clock, so the same 80 is divided over however many domains
  # Corpus derives. `SEEDS=` still sets a per-domain count locally.
  SEED_BUDGET = 80
  SEEDS_PER_DOMAIN = Integer(ENV["SEEDS"] || (SEED_BUDGET.to_f / DOMAINS.size).ceil)
  STEPS_PER_SEQUENCE = 25
  # Opt-in, off in CI — `SequenceGenerator`'s adversarial layer
  # (sequence_generator/adversary.rb) is what `bin/qa_sweep` runs by
  # default; here it stays at 0 so this gate keeps pinning exactly the
  # sequences it always has. `ADVERSARIAL=0.3 bundle exec rspec
  # spec/rust_conformance_fuzz_spec.rb --tag io` turns it on locally
  # when hunting, the same way `SEEDS=` already widens the pass.
  ADVERSARIAL_FRACTION = Float(ENV["ADVERSARIAL"] || 0)

  def build_rust_for(domain_feature) = super(domain_feature, FUZZ_RUST_DIR)

  it "pends only domains it actually fuzzes" do
    expect(RUST_FUZZ_PENDING.keys - DOMAINS.map { |domain| File.basename(domain) }).to be_empty
  end

  DOMAINS.each do |domain|
    describe File.basename(domain) do
      # A real cargo-built binary compared field-by-field (instances,
      # events, refusals, queries, sagas, reactions) across every
      # generated seed, accumulating one combined divergence report —
      # splitting per field or per seed would re-pay the cargo build and
      # subprocess spawns, and would scatter one seed's related
      # divergences across separate failures instead of one readable report.
      # Both examples gate now — ADR 0037's own catalogue (findings 3, 4,
      # 5, 6, 7) is fully closed; no `pending:` left on either domain.

      # rubocop:disable-next RSpec/ExampleLength
      it "agrees with Ruby across #{SEEDS_PER_DOMAIN} generated sequences (instances, events, refusals, " \
         "reactions, sagas, queries)" do
        pending RUST_FUZZ_PENDING.fetch(File.basename(domain)) if RUST_FUZZ_PENDING.key?(File.basename(domain))
        feature = File.basename(domain).downcase
        binary = build_rust_for(feature)
        skip "rust/Cargo.toml has no #{feature} feature — run bin/project_rust for it first" unless binary

        gaps = Hecks::Fuzzing::RustGapManifest.for_binary(binary)
        divergences = []

        (1..SEEDS_PER_DOMAIN).each do |seed|
          steps = Hecks::Fuzzing::SequenceGenerator.generate(domain, seed: seed, steps: STEPS_PER_SEQUENCE,
                                                                        adversarial: ADVERSARIAL_FRACTION)

          ruby_result = Hecks::Fuzzing::Replay.call(domain, steps)
          ruby_instances = JSON.parse(JSON.generate(ruby_result[:instances]))
          ruby_events    = JSON.parse(JSON.generate(ruby_result[:events]))
          # Refusals are compared by kind, not wording (C8.2, docs/semantics/
          # bluebook-semantics.md: prose is not the contract) — the same
          # rule spec/semantics_corpus_spec.rb holds both kernels to. The
          # message rides along into the manifest partition below, then drops.
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

          # **Tolerated only where the manifest says so** — a query/read-model
          # verb this binary's manifest.json declares `generated: false`
          # leaves both sides; any other refusal is compared, whatever its
          # wording. A tolerated verb Rust answered anyway is its own
          # divergence (a stale manifest).
          kept = Hecks::Fuzzing::Differential.manifest_partition(
            gaps, ruby_refusals: ruby_refusals, rust_refusals: rust_output["refusals"],
                  ruby_queries: ruby_queries, rust_queries: rust_output["queries"]
          )
          kept[:stale].each { |stale| divergences << stale.merge(seed: seed) }

          by_kind = ->(r) { r.slice("verb", "kind") }
          rust_refusals = kept[:rust_refusals].map(&by_kind)
          kept_ruby_refusals = kept[:ruby_refusals].map(&by_kind)
          if rust_refusals != kept_ruby_refusals
            divergences << { seed: seed, field: "refusals",
                              ruby: kept_ruby_refusals, rust: rust_refusals }
          end

          wordless = ->(q) { reduce_to_wire_precision(q.except("error", "reference_error")) }
          rust_queries = kept[:rust_queries].map(&wordless)
          kept_ruby_queries = kept[:ruby_queries].map(&wordless)
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
                                    .reject { |r| cross_domain.include?(r["policy"]) }
          rust_reactions = rust_output.fetch("reactions")
          if rust_reactions != kept_ruby_reactions
            divergences << { seed: seed, field: "reactions",
                              ruby: kept_ruby_reactions, rust: rust_reactions }
          end
        end

        # **A real divergence here is a finding, not just a failing spec** —
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
