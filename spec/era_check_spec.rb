require "spec_helper"
require "tmpdir"

# The boot-time gate for adapters that HAVE eras. Eras are facts about
# stored data some adapter can carry across a shape change, so only a
# lineage-capable adapter holds them — everything else has no era, holds
# nothing, and is never lectured about drift it could not act on. (The
# Postgres side of this lives in spec/adapters/postgres_lineage_spec.rb.)
#
# What remains adapter-agnostic is the compute gate, which was never an
# era fact. Its refusal is pinned byte-for-byte — the Rust twin asserts
# the SAME string against the same fixture
# (rust/src/runtime/era_check.rs).
RSpec.describe "the era check at boot" do
  ERA_FIXTURES = File.join(InMemoryDomain::ROOT, "spec", "fixtures", "eras")

  ERA_V1 = File.read(File.join(ERA_FIXTURES, "base.bluebook"))
  ERA_DRIFTED = File.read(File.join(ERA_FIXTURES, "bump_attribute_rename.bluebook"))
  ERA_BEHAVIOR_ONLY = File.read(File.join(ERA_FIXTURES, "same_behavior.bluebook"))

  def load_domain(root, source, translation_source: nil)
    domain_dir = File.join(root, "bluebook")
    # A fresh file per load: the predicate extractor caches source by
    # path, so rewriting one path with different text would hand later
    # loads stale lines.
    FileUtils.rm_rf(domain_dir)
    FileUtils.mkdir_p(domain_dir)
    @load_count = (@load_count || 0) + 1
    path = File.join(domain_dir, "shaped_#{@load_count}.bluebook")
    File.write(path, source)

    registry = Hecksagain::Runtime::Registry.new(root: root)
    loading = Hecksagain::Ports::Loading.bootstrap
    Hecksagain.with_registry(registry) do
      loading.load_library
      Kernel.eval(source, TOPLEVEL_BINDING, path, 1)
      eval(translation_source) if translation_source
    end
    [registry, domain_dir]
  end

  def check!(root, source, translation_source: nil)
    registry, domain_dir = load_domain(root, source, translation_source: translation_source)
    Hecksagain::Runtime::EraCheck.check!(registry, domain_dir)
    registry
  end

  it "holds nothing for an adapter that has no eras, and never refuses its drift" do
    Dir.mktmpdir do |root|
      check!(root, ERA_V1)
      expect(Dir.exist?(File.join(root, "data", "eras"))).to be(false)

      # the shape moves, twice, and Memory is never lectured about a
      # translation it could not apply
      expect { check!(root, ERA_DRIFTED) }.not_to raise_error
      expect { check!(root, ERA_BEHAVIOR_ONLY) }.not_to raise_error
      expect(Dir.exist?(File.join(root, "data", "eras"))).to be(false)
    end
  end

  it "refuses a compute rule per-rule and by name on any non-Postgres adapter" do
    Dir.mktmpdir do |root|
      translation = <<~RUBY
        Hecks.data_translation("Shaped", from: "1", to: "2") do
          aggregate("Account") { compute "price_cents", to: "price_dollars", sql: "price_cents::numeric / 100" }
        end
      RUBY

      expect { check!(root, ERA_V1, translation_source: translation) }.to raise_error(
        Hecksagain::Runtime::WiringError,
        "compute rules require the Postgres adapter; Account is bound to Memory"
      )
    end
  end

  it "re-attestation recomputes the era name: cosmetic edits pass, a shape change refuses hard" do
    Dir.mktmpdir do |root|
      registry, = load_domain(root, ERA_V1)
      bluebook = registry.bluebook("Shaped")
      stored_hash = Hecksagain::Runtime::StorageShape.mint_hash(bluebook)

      # comments and whitespace still project to the minted name
      cosmetic = "# an operator fixed a typo in a comment\n#{ERA_V1}"
      expect(
        Hecksagain::Translation::Reattest.shape_guard!(
          domain: "Shaped", ordinal: 1, text: cosmetic, stored_hash: stored_hash
        )
      ).to eq(:cosmetic)

      # a shape edit would retroactively redefine era 1 — no --accept
      # gets past this
      expect do
        Hecksagain::Translation::Reattest.shape_guard!(
          domain: "Shaped", ordinal: 1, text: ERA_DRIFTED, stored_hash: stored_hash
        )
      end.to raise_error(
        Hecksagain::Runtime::WiringError,
        /the edit changed the era's SHAPE, not just its text.*retroactively redefine what era 1 meant/m
      )

      # unloadable text is not attestable at all — held texts are
      # bootable source
      expect do
        Hecksagain::Translation::Reattest.shape_guard!(
          domain: "Shaped", ordinal: 1, text: "Hecks.bluebook \"Shaped\" do\n  vision \"\"\nend\n", stored_hash: stored_hash
        )
      end.to raise_error(Hecksagain::Runtime::WiringError, /does not load as a bluebook/)

      # an era that was never named cannot be shape-checked — reported,
      # not refused
      expect(
        Hecksagain::Translation::Reattest.shape_guard!(
          domain: "Shaped", ordinal: 1, text: ERA_DRIFTED, stored_hash: nil
        )
      ).to eq(:unnamed)
    end
  end

  it "the shape guard prefers the stored projection, so it survives a canonical-form change" do
    Dir.mktmpdir do |root|
      registry, = load_domain(root, ERA_V1)
      bluebook = registry.bluebook("Shaped")
      # JSON round-trip: stored projections come back string-keyed
      projection = JSON.parse(JSON.generate(Hecksagain::Runtime::StorageShape.project(bluebook)))

      # a hash minted under a DIFFERENT canonical form would no longer
      # match a recomputation — the projection comparison must win, or
      # every cosmetic edit to an old-form era false-refuses
      wrong_form_hash = "0" * 64
      cosmetic = "# an operator fixed a typo in a comment\n#{ERA_V1}"
      expect(
        Hecksagain::Translation::Reattest.shape_guard!(
          domain: "Shaped", ordinal: 1, text: cosmetic,
          stored_hash: wrong_form_hash, stored_projection: projection
        )
      ).to eq(:cosmetic)

      # and a real shape change still refuses, judged structurally
      expect do
        Hecksagain::Translation::Reattest.shape_guard!(
          domain: "Shaped", ordinal: 1, text: ERA_DRIFTED,
          stored_hash: wrong_form_hash, stored_projection: projection
        )
      end.to raise_error(
        Hecksagain::Runtime::WiringError,
        /no longer projects to the shape frozen for era 1.*retroactively redefine what era 1 meant/m
      )

      # a stored projection also lets an UNNAMED era be shape-checked —
      # strictly better than the :unnamed shrug
      expect(
        Hecksagain::Translation::Reattest.shape_guard!(
          domain: "Shaped", ordinal: 1, text: cosmetic,
          stored_hash: nil, stored_projection: projection
        )
      ).to eq(:cosmetic)
    end
  end
end
