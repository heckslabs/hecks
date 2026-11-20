require "json"
require "hecks/fuzzing"
require "hecks/fuzzing/differential"
require_relative "support/rust_conformance_helpers"
require_relative "support/generated_rust"

# Diffs Ruby against the compiled Rust kernel over seeded generated sequences per domain, through
# `Differential.diff` with the kernel served over the host protocol (`Differential::ServeEngine`,
# one warm `--serve` per domain). Needs a real `cargo build` per domain (`:io`), and is kept apart
# from the hand-curated spec/rust_conformance_spec.rb corpus.
RSpec.describe "Rust conformance, over generated sequences (native binary)", :io do
  include_context "with the generated Rust tree"

  include RustConformanceHelpers

  FUZZ_RUST_DIR = File.join(InMemoryDomain::ROOT, "rust")

  # Every in-repo domain with a cargo feature, from the same Corpus list the codegen drift
  # check uses; the `meta` feature has no domain directory (see Corpus::RUST_ELSEWHERE).
  DOMAINS = Hecks::Corpus.rust_domains.map(&:dir).freeze

  # A domain that still diverges, with the bug that owns it. It runs as `pending`, so the
  # example fails once the domain agrees and the entry must be deleted.
  RUST_FUZZ_PENDING = {
    "ledgerbook" => "the first fuzz of this domain found Ruby refusing Shelf.Stock with NotFound where the " \
                    "Rust kernel stocks the shelf, taking an empty slot as part of a composite identity " \
                    "(`juliet:`); the two runtimes disagree on which instances exist, so events, refusals " \
                    "and reactions follow"
  }.freeze

  # A total spread across `DOMAINS`, so a longer domain list adds no wall-clock.
  # `SEEDS=` sets a per-domain count instead; keep it modest, each seed spawns a subprocess.
  SEED_BUDGET = 80
  SEEDS_PER_DOMAIN = Integer(ENV["SEEDS"] || (SEED_BUDGET.to_f / DOMAINS.size).ceil)
  STEPS_PER_SEQUENCE = 25
  # Fraction of adversarial steps (sequence_generator/adversary.rb); 0 in CI so the gate
  # pins the same sequences. Set `ADVERSARIAL=0.3` locally when hunting.
  ADVERSARIAL_FRACTION = Float(ENV["ADVERSARIAL"] || 0)

  def build_rust_for(domain_feature) = super(domain_feature, FUZZ_RUST_DIR)

  # The comparison helpers `Differential.diff` takes; tolerated verbs collect in `structural_skips`.
  def differ
    Class.new do
      include RustConformanceHelpers

      def structural_skips = @structural_skips ||= Set.new
    end.new
  end

  # The domain's kernel served over the host protocol, or a skip when it has no Cargo feature.
  def served_kernel(domain)
    feature = File.basename(domain).downcase
    binary = build_rust_for(feature)
    skip "rust/Cargo.toml has no #{feature} feature — run hecks project_rust for it first" unless binary
    Hecks::Fuzzing::Differential::ServeEngine.new(binary)
  end

  # The `:differential` divergences of one seed, each tagged with the seed.
  def seed_divergences(domain, seed, engine)
    steps = Hecks::Fuzzing::SequenceGenerator.generate(domain, seed: seed, steps: STEPS_PER_SEQUENCE,
                                                                  adversarial: ADVERSARIAL_FRACTION)
    Hecks::Fuzzing::Differential.diff(differ, domain, steps, engine, modes: [:differential])
                                .fetch(:differential).map { |divergence| divergence.merge(seed: seed) }
  end

  # A served kernel that drops the last step, so it must disagree with Ruby.
  def short_engine(engine)
    Class.new(SimpleDelegator) { def call(domain, steps, **) = __getobj__.call(domain, steps[0...-1], **) }.new(engine)
  end

  it "pends only domains it actually fuzzes" do
    expect(RUST_FUZZ_PENDING.keys - DOMAINS.map { |domain| File.basename(domain) }).to be_empty
  end

  it "finds a seeded divergence over the served kernel" do
    domain = File.join(InMemoryDomain::ROOT, "examples/chess")
    steps = JSON.parse(File.read(File.join(InMemoryDomain::ROOT, "spec/corpus/chess.json"))).fetch("steps")
    engine = served_kernel(domain)
    found = Hecks::Fuzzing::Differential.diff(differ, domain, steps, short_engine(engine), modes: [:differential])
    expect(found.fetch(:differential).map { |divergence| divergence[:field] }).to include("events")
  ensure
    engine&.close
  end

  DOMAINS.each do |domain|
    describe File.basename(domain) do
      # One example accumulates a combined divergence report across all seeds and fields;
      # splitting would re-pay the cargo build and scatter related divergences.
      it "agrees with Ruby across #{SEEDS_PER_DOMAIN} generated sequences (instances, events, refusals, " \
         "reactions, sagas, queries, dry runs)" do
        pending RUST_FUZZ_PENDING.fetch(File.basename(domain)) if RUST_FUZZ_PENDING.key?(File.basename(domain))
        engine = served_kernel(domain)
        divergences = (1..SEEDS_PER_DOMAIN).flat_map { |seed| seed_divergences(domain, seed, engine) }

        # A divergence is a finding: shrink it with `hecks fuzz shrink <domain> <seed>` first.
        # Printed so the seed and field are not buried in a large diff.
        message = divergences.map do |d|
          "seed #{d[:seed]} — #{d[:field]}" +
            (d[:detail] ? ": #{d[:detail]}" : "\n  ruby: #{d[:ruby].inspect}\n  rust: #{d[:rust].inspect}")
        end.join("\n")

        expect(divergences).to be_empty, "#{divergences.size} divergence(s) found — reproduce with " \
                                         "`SEEDS=1 bundle exec rspec` after isolating the seed below, " \
                                         "then shrink with hecks fuzz:\n#{message}"
      ensure
        engine&.close
      end
    end
  end
end
