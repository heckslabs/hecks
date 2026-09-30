require "json"
require "open3"
require "hecks/fuzzing"
require "hecks/fuzzing/differential"
require_relative "support/rust_conformance_helpers"

# Diffs Ruby against the compiled Rust binary over seeded generated sequences per domain.
# Needs a real `cargo build` per domain (`:io`), and is kept apart from the hand-curated
# spec/rust_conformance_spec.rb corpus.
RSpec.describe "Rust conformance, over generated sequences (native binary)", :io do
  include RustConformanceHelpers

  FUZZ_RUST_DIR = File.join(InMemoryDomain::ROOT, "rust")

  # Every in-repo domain with a cargo feature, from the same Corpus list the codegen drift
  # check uses; the `meta` feature has no domain directory (see Corpus::RUST_ELSEWHERE).
  DOMAINS = Hecks::Corpus.rust_domains.map(&:dir).freeze

  # A domain that still diverges, with the bug that owns it. It runs as `pending`, so the
  # example fails once the domain agrees and the entry must be deleted.
  RUST_FUZZ_PENDING = {}.freeze

  # A total spread across `DOMAINS`, so a longer domain list adds no wall-clock.
  # `SEEDS=` sets a per-domain count instead; keep it modest, each seed spawns a subprocess.
  SEED_BUDGET = 80
  SEEDS_PER_DOMAIN = Integer(ENV["SEEDS"] || (SEED_BUDGET.to_f / DOMAINS.size).ceil)
  STEPS_PER_SEQUENCE = 25
  # Fraction of adversarial steps (sequence_generator/adversary.rb); 0 in CI so the gate
  # pins the same sequences. Set `ADVERSARIAL=0.3` locally when hunting.
  ADVERSARIAL_FRACTION = Float(ENV["ADVERSARIAL"] || 0)

  def build_rust_for(domain_feature) = super(domain_feature, FUZZ_RUST_DIR)

  it "pends only domains it actually fuzzes" do
    expect(RUST_FUZZ_PENDING.keys - DOMAINS.map { |domain| File.basename(domain) }).to be_empty
  end

  DOMAINS.each do |domain|
    describe File.basename(domain) do
      # One example accumulates a combined divergence report across all seeds and fields;
      # splitting would re-pay the cargo build and scatter related divergences.
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
          # Refusals compare by kind, not wording (C8.2); the message rides along only
          # into the manifest partition below.
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

          # Verbs the manifest declares `generated: false` leave both sides; a tolerated
          # verb Rust answered anyway is a stale manifest, reported as a divergence.
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

        # A divergence is a finding: shrink it with `bin/fuzz shrink <domain> <seed>` first.
        # Printed so the seed and field are not buried in a large diff.
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
