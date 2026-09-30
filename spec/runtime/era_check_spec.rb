require "spec_helper"
require "hecks/ports/persistence/plugins/era"
require "tmpdir"

# The boot-time era gate: only lineage-capable adapters hold eras (Postgres side in
# spec/adapters/postgres_lineage_spec.rb). The compute gate's refusal wording is pinned.
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

    registry = Hecks::Runtime::Registry.new(root: root)
    loading = Hecks::Ports::Loading.bootstrap
    Hecks.with_registry(registry) do
      loading.load_library
      Kernel.eval(source, TOPLEVEL_BINDING, path, 1)
      eval(translation_source) if translation_source
    end
    [registry, domain_dir]
  end

  def check!(root, source, translation_source: nil)
    registry, domain_dir = load_domain(root, source, translation_source: translation_source)
    Hecks::Runtime::EraCheck.check!(registry, domain_dir)
    registry
  end

  # Shared by the shape_guard! examples below: booting "Shaped" and
  # fetching its bluebook is identical setup each uses before deriving
  # its own stored_hash/projection to check re-attestation against.
  def shaped_bluebook(root, source: ERA_V1)
    registry, = load_domain(root, source)
    registry.bluebook("Shaped")
  end

  # JSON round-trip: stored projections come back string-keyed.
  def shaped_projection(root, source: ERA_V1)
    JSON.parse(JSON.generate(Hecks::Runtime::StorageShape.project(shaped_bluebook(root, source: source))))
  end

  it "reads source containing non-ASCII bytes even when the process default external encoding is US-ASCII" do
    # The production container runs with no locale, so the default external encoding is
    # us-ASCII; an em-dash in a .bluebook comment raised ArgumentError.
    previous_external = Encoding.default_external
    Encoding.default_external = Encoding::US_ASCII
    begin
      Dir.mktmpdir do |root|
        source = "Hecks.bluebook \"Shaped\" do\n  vision \"an em dash — right here\"\nend\n"
        File.write(File.join(root, "a.bluebook"), source)

        bluebook = Struct.new(:name).new("Shaped")
        expect(Hecks::Runtime::EraCheck.source_text_for(bluebook, root)).to eq(source)
      end
    ensure
      Encoding.default_external = previous_external
    end
  end

  it "snapshots every concept file for one chapter, in deterministic order" do
    Dir.mktmpdir do |root|
      second = "Hecks.bluebook \"Shaped\" do\n  aggregate \"Second\" do\n  end\nend\n"
      first = "Hecks.bluebook \"Shaped\" do\n  vision \"first\"\nend\n"
      other = "Hecks.bluebook \"Other\" do\n  vision \"not part of Shaped\"\nend\n"
      File.write(File.join(root, "b.bluebook"), second)
      File.write(File.join(root, "a.bluebook"), first)
      File.write(File.join(root, "other.bluebook"), other)

      bluebook = Struct.new(:name).new("Shaped")
      expect(Hecks::Runtime::EraCheck.source_text_for(bluebook, root)).to eq("#{first}\n#{second}")
    end
  end

  it "holds nothing for an adapter that has no eras, and never refuses its drift" do
    Dir.mktmpdir do |root|
      check!(root, ERA_V1)
      expect(Dir.exist?(File.join(root, "data", "eras"))).to be(false)

      # the shape moves twice without refusal: Memory has no translation to apply
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
        Hecks::Runtime::WiringError,
        "compute rules require the Postgres adapter; Account is bound to Memory"
      )
    end
  end

  it "cosmetic edits (comments, whitespace) still project to the minted era name" do
    Dir.mktmpdir do |root|
      stored_hash = Hecks::Runtime::StorageShape.mint_hash(shaped_bluebook(root))
      cosmetic = "# an operator fixed a typo in a comment\n#{ERA_V1}"

      expect(
        Hecks::Translation::Reattest.shape_guard!(
          domain: "Shaped", ordinal: 1, text: cosmetic, stored_hash: stored_hash
        )
      ).to eq(:cosmetic)
    end
  end

  it "a shape edit would retroactively redefine era 1 — no --accept gets past this" do
    Dir.mktmpdir do |root|
      stored_hash = Hecks::Runtime::StorageShape.mint_hash(shaped_bluebook(root))

      expect do
        Hecks::Translation::Reattest.shape_guard!(
          domain: "Shaped", ordinal: 1, text: ERA_DRIFTED, stored_hash: stored_hash
        )
      end.to raise_error(
        Hecks::Runtime::WiringError,
        /the edit changed the era's SHAPE, not just its text.*retroactively redefine what era 1 meant/m
      )
    end
  end

  # A plain syntax error, not a meta-domain rule: shadow_parse's grammar must not
  # refuse frozen era texts that boot.
  it "unloadable text is not attestable at all" do
    Dir.mktmpdir do |root|
      stored_hash = Hecks::Runtime::StorageShape.mint_hash(shaped_bluebook(root))

      expect do
        Hecks::Translation::Reattest.shape_guard!(
          domain: "Shaped", ordinal: 1, text: "Hecks.bluebook \"Shaped\" do\n  ((((\nend\n", stored_hash: stored_hash
        )
      end.to raise_error(Hecks::Runtime::WiringError, /does not load as a bluebook/)
    end
  end

  it "an era that was never named cannot be shape-checked — reported, not refused" do
    expect(
      Hecks::Translation::Reattest.shape_guard!(
        domain: "Shaped", ordinal: 1, text: ERA_DRIFTED, stored_hash: nil
      )
    ).to eq(:unnamed)
  end

  # A hash minted under a different canonical form does not match a recomputation, so
  # the projection comparison must win or cosmetic edits to an old-form era false-refuse.
  it "prefers a matching stored projection over a stored_hash minted under a different canonical form" do
    Dir.mktmpdir do |root|
      projection = shaped_projection(root)
      wrong_form_hash = "0" * 64
      cosmetic = "# an operator fixed a typo in a comment\n#{ERA_V1}"

      expect(
        Hecks::Translation::Reattest.shape_guard!(
          domain: "Shaped", ordinal: 1, text: cosmetic,
          stored_hash: wrong_form_hash, stored_projection: projection
        )
      ).to eq(:cosmetic)
    end
  end

  it "a real shape change still refuses under stored_projection, judged structurally" do
    Dir.mktmpdir do |root|
      projection = shaped_projection(root)
      wrong_form_hash = "0" * 64

      expect do
        Hecks::Translation::Reattest.shape_guard!(
          domain: "Shaped", ordinal: 1, text: ERA_DRIFTED,
          stored_hash: wrong_form_hash, stored_projection: projection
        )
      end.to raise_error(
        Hecks::Runtime::WiringError,
        /no longer projects to the shape frozen for era 1.*retroactively redefine what era 1 meant/m
      )
    end
  end

  describe "the shape verdict `Era.Permit`'s givens hold, which never raises" do
    it "answers every way an edited text can stand against the frozen shape" do
      Dir.mktmpdir do |root|
        projection = shaped_projection(root)
        stored_hash = Hecks::Runtime::StorageShape.mint_hash(shaped_bluebook(root))
        cosmetic = "# an operator fixed a typo in a comment\n#{ERA_V1}"
        broken = "Hecks.bluebook \"Shaped\" do\n  ((((\nend\n"
        verdict = lambda do |text, **stored|
          Hecks::Translation::Reattest.verdict(text: text, stored_hash: nil, **stored)
        end

        expect(verdict.call(cosmetic, stored_projection: projection)).to eq(:cosmetic)
        expect(verdict.call(cosmetic, stored_hash: stored_hash)).to eq(:cosmetic)
        expect(verdict.call(ERA_DRIFTED, stored_projection: projection)).to eq(:changed)
        expect(verdict.call(ERA_DRIFTED, stored_hash: stored_hash)).to eq(:changed)
        expect(verdict.call(cosmetic)).to eq(:unnamed)
        expect(verdict.call(broken, stored_projection: projection)).to eq(:unloadable)
      end
    end

    it "is what shape_guard! raises on: the same words for a hash-named era" do
      Dir.mktmpdir do |root|
        stored_hash = Hecks::Runtime::StorageShape.mint_hash(shaped_bluebook(root))
        label = Hecks::Runtime::StorageShape::LABEL_LENGTH

        expect do
          Hecks::Translation::Reattest.shape_guard!(
            domain: "Shaped", ordinal: 1, text: ERA_DRIFTED, stored_hash: stored_hash
          )
        end.to raise_error(
          Hecks::Runtime::WiringError,
          /its name #{stored_hash[0, label]} was minted from a different shape.*retroactively redefine/m
        )
      end
    end
  end

  it "a stored projection lets an UNNAMED era be shape-checked, not just shrugged at" do
    Dir.mktmpdir do |root|
      projection = shaped_projection(root)
      cosmetic = "# an operator fixed a typo in a comment\n#{ERA_V1}"

      expect(
        Hecks::Translation::Reattest.shape_guard!(
          domain: "Shaped", ordinal: 1, text: cosmetic,
          stored_hash: nil, stored_projection: projection
        )
      ).to eq(:cosmetic)
    end
  end
end
