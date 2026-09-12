require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/fuzzing"

# `Hecks::Fuzzing::TargetCapabilities` — the ONE rule `bin/qa_sweep`
# resolves its modes by (`enabled ∩ eligible`), checked two ways: the
# inference reads REAL corpus directories (so a regex here can never
# quietly stop matching what the harness actually ships), and the
# resolution is pinned against hand-built capability sets so the
# `MODE_REQUIREMENTS` table is itself a tested fact. `StructuralSkips`
# rides along at the bottom: same file, same reason — both exist so a
# "quiet divergence" (a stale Cargo feature, a codegen regression hiding
# behind "not generated") becomes a printed, logged fact.
RSpec.describe Hecks::Fuzzing::TargetCapabilities do
  CAP_ROOT      = InMemoryDomain::ROOT
  CAP_RUST_DIR  = File.join(CAP_ROOT, "rust")
  CAP_BANKING   = File.join(CAP_ROOT, "examples/banking")
  CAP_DIRECTORY = File.join(CAP_ROOT, "examples/directory")
  CAP_PIZZAS    = File.join(CAP_ROOT, "examples/pizzas")
  CAP_CHESS     = File.join(CAP_ROOT, "examples/chess")

  def infer(path) = described_class.infer(path, rust_dir: CAP_RUST_DIR)

  describe ".infer, against the real corpus" do
    it "reads banking's rust feature, Governance attachment, role gates, tenant scope and sagas off disk" do
      expect(infer(CAP_BANKING)).to include("rust", "governance", "role_gated", "tenant", "sagas", "sqlite")
      expect(infer(CAP_BANKING)).not_to include("postgres_era")
    end

    it "reads directory's PostgresEra binding and translation edge, and its lack of a rust feature" do
      expect(infer(CAP_DIRECTORY)).to include("postgres_era", "translations", "sqlite")
      expect(infer(CAP_DIRECTORY)).not_to include("rust", "role_gated", "sagas")
    end

    it "always answers sqlite, sorted, as plain strings" do
      capabilities = infer(CAP_CHESS)
      expect(capabilities).to include("sqlite")
      expect(capabilities).to eq(capabilities.sort)
      expect(capabilities).to all(be_a(String))
    end

    it "scopes the rust feature lookup to Cargo.toml's [features] table, never the crate's own name" do
      Dir.mktmpdir do |tmp|
        rust_dir = File.join(tmp, "rust")
        FileUtils.mkdir_p(rust_dir)
        # `[package] name = "rust"` and `[[bin]] name = "rust"` both name a
        # domain called `rust` OUTSIDE the features table — neither may
        # read as a feature.
        File.write(File.join(rust_dir, "Cargo.toml"), <<~TOML)
          [features]
          default = ["widget"]
          widget = []

          [package]
          name = "rust"

          [[bin]]
          name = "rust"
        TOML
        widget = File.join(tmp, "widget")
        rust   = File.join(tmp, "rust_domain")
        FileUtils.mkdir_p(widget)
        FileUtils.mkdir_p(rust)

        expect(described_class.infer(widget, rust_dir: rust_dir)).to include("rust")
        expect(described_class.infer(File.join(tmp, "rust"), rust_dir: rust_dir)).not_to include("rust")
      end
    end

    it "answers no rust capability at all when there is no Cargo.toml to read" do
      Dir.mktmpdir do |tmp|
        expect(described_class.infer(CAP_PIZZAS, rust_dir: File.join(tmp, "nowhere"))).not_to include("rust")
      end
    end
  end

  describe ".resolve — the one rule" do
    let(:all_enabled) { described_class::MODE_REQUIREMENTS.keys }

    it "keeps the enabled order, and keeps only what the capabilities admit" do
      resolved = described_class.resolve(all_enabled, %w[rust sqlite])
      expect(resolved).to eq(%i[differential self_consistency properties_in_differential structural_skip_report
                                adapter_parity_sqlite wasm_front])
    end

    it "drops ruby_only whenever differential resolved — they are the same seat" do
      expect(described_class.resolve(%i[differential ruby_only], %w[rust sqlite])).to eq(%i[differential])
      expect(described_class.resolve(%i[differential ruby_only], %w[sqlite])).to eq(%i[ruby_only])
    end

    it "resolves persistence_parity, era_boundary and concurrency only off a PostgresEra binding" do
      expect(described_class.resolve(all_enabled, %w[postgres_era sqlite translations]))
        .to include(:persistence_parity, :era_boundary, :concurrency, :adapter_parity_postgres)
      expect(described_class.resolve(all_enabled, %w[sqlite translations]))
        .not_to include(:persistence_parity, :era_boundary, :concurrency)
    end

    it "requires BOTH translations and postgres_era for era_boundary" do
      expect(described_class.eligible?(:era_boundary, %w[postgres_era sqlite])).to be(false)
      expect(described_class.eligible?(:era_boundary, %w[postgres_era sqlite translations])).to be(true)
    end

    it "refuses a mode name nothing declares, rather than silently resolving it away" do
      expect { described_class.eligible?(:telepathy, %w[sqlite]) }.to raise_error(ArgumentError, /telepathy/)
    end

    it "names every DEFERRED mode in MODE_REQUIREMENTS, and every dial mode too" do
      expect(described_class::DEFERRED_MODES - described_class::MODE_REQUIREMENTS.keys).to be_empty

      # The dial and the requirements table must agree on the mode
      # vocabulary in BOTH directions — a mode one names and the other
      # doesn't is exactly the drift `resolve` would silently hide.
      define_dials!
      expect(QualityControlDials::MODES.keys).to match_array(described_class::MODE_REQUIREMENTS.keys)
    end
  end

  # THE DIAL, READ WITHOUT TOUCHING THE LIVE LEDGER — `QualityControlDials`
  # is a constant the bluebook file defines while loading, and a bluebook
  # only loads inside a boot. `IsolatedBoot` (via `Replay.call` with no
  # steps) boots a throwaway COPY of qa/bluebook rebound to Memory, the
  # same door every fuzz path uses — never the real `hecks_quality_control`
  # database (`spec/quality_control_spec.rb`'s own header on why that
  # would be unacceptable).
  def define_dials!
    return if defined?(QualityControlDials::MODES)

    Hecks::Fuzzing::Replay.call(File.join(CAP_ROOT, "qa/bluebook"), [])
  end

  describe "the live corpus, resolved against the dial" do
    before { define_dials! }

    let(:enabled) { QualityControlDials::MODES.select { |_, on| on }.keys }

    it "gives banking the differential seat plus properties, self-consistency and the skip report" do
      expect(described_class.resolve(enabled, infer(CAP_BANKING)))
        .to eq(%i[differential self_consistency properties_in_differential structural_skip_report])
    end

    it "gives directory the ruby_only seat plus self-consistency and persistence parity" do
      expect(described_class.resolve(enabled, infer(CAP_DIRECTORY)))
        .to eq(%i[ruby_only self_consistency persistence_parity])
    end
  end

  describe Hecks::Fuzzing::StructuralSkips do
    let(:skips) { described_class }
    let(:bluebooks) { Hecks::Fuzzing::Replay.call(CAP_BANKING, [])[:bluebooks] }

    it "attributes a declared query to the constructs its own declaration carries" do
      constructs = skips.constructs_of(bluebooks, "Banking::ATMCard.ByFee")
      expect(constructs).to include("limit", "offset", "order_by", "where_literal")
    end

    it "attributes a rootless, grouped read model to rootless + group_by" do
      expect(skips.constructs_of(bluebooks, "Banking.accounts_by_kind")).to include("rootless", "group_by")
    end

    it "answers `unknown` for a verb Ruby never declared — a stale generated tree is not a boundary" do
      expect(skips.constructs_of(bluebooks, "Banking::Account.NoSuchQuery")).to eq(%w[unknown])
      expect(skips.constructs_of(bluebooks, "Banking.no_such_report")).to eq(%w[unknown])
    end

    it "flags a skipped verb with no admitted construct, and passes one whose constructs the boundary admits" do
      attributed = skips.attribute(bluebooks, %w[Banking::ATMCard.ByFee Banking.customer_portfolio])
      outside    = skips.outside_boundary(attributed, %w[limit offset order_by where_literal])

      # `customer_portfolio` is a rooted read model with nothing but heads —
      # the generated subset. If Rust ever refused it as "not generated",
      # nothing explains the skip: that is the surprise this exists for.
      expect(outside.map { |e| e[:verb] }).to eq(%w[Banking.customer_portfolio])
    end

    it "flags a construct the boundary does not admit" do
      attributed = skips.attribute(bluebooks, %w[Banking::ATMCard.ByFee])
      expect(skips.outside_boundary(attributed, %w[limit order_by]).map { |e| e[:verb] })
        .to eq(%w[Banking::ATMCard.ByFee])
      expect(skips.outside_boundary(attributed, %w[limit offset order_by where_literal])).to be_empty
    end
  end
end
