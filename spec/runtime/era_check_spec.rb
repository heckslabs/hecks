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
  ERA_BROKEN = "Hecks.bluebook \"Shaped\" do\n  ((((\nend\n".freeze
  ERA_COSMETIC = "# an operator fixed a typo in a comment\n#{ERA_V1}".freeze
  ERA_WRONG_FORM_HASH = ("0" * 64).freeze

  ERA_COMPUTE_TRANSLATION = <<~RUBY.freeze
    Hecks.data_translation("Shaped", from: "1", to: "2") do
      aggregate("Account") { compute "price_cents", to: "price_dollars", sql: "price_cents::numeric / 100" }
    end
  RUBY

  around do |example|
    Dir.mktmpdir do |dir|
      @root = dir
      example.run
    end
  end

  attr_reader :root

  # A fresh file per load: the predicate extractor caches source by
  # path, so rewriting one path with different text would hand later
  # loads stale lines.
  def write_fresh_bluebook(domain_dir, source)
    FileUtils.rm_rf(domain_dir)
    FileUtils.mkdir_p(domain_dir)
    @load_count = (@load_count || 0) + 1
    path = File.join(domain_dir, "shaped_#{@load_count}.bluebook")
    File.write(path, source)
    path
  end

  def load_domain(root, source, translation_source: nil)
    domain_dir = File.join(root, "bluebook")
    path = write_fresh_bluebook(domain_dir, source)

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

  def minted_hash = Hecks::Runtime::StorageShape.mint_hash(shaped_bluebook(root))

  def guard(**stored) = Hecks::Translation::Reattest.shape_guard!(domain: "Shaped", ordinal: 1, **stored)

  def verdict(text, **stored) = Hecks::Translation::Reattest.verdict(text: text, stored_hash: nil, **stored)

  def source_text_for(name, directory)
    Hecks::Runtime::EraCheck.source_text_for(Struct.new(:name).new(name), directory)
  end

  # The production container runs with no locale, so the default external encoding is us-ASCII.
  def with_us_ascii_default_encoding
    previous_external = Encoding.default_external
    Encoding.default_external = Encoding::US_ASCII
    yield
  ensure
    Encoding.default_external = previous_external
  end

  # Writes one chapter across two files (b before a on disk) plus an unrelated chapter's file.
  #
  # @return [Array<String>] the two texts of the chapter, in the order they should be read
  def write_chapter_files
    second = "Hecks.bluebook \"Shaped\" do\n  aggregate \"Second\" do\n  end\nend\n"
    first = "Hecks.bluebook \"Shaped\" do\n  vision \"first\"\nend\n"
    File.write(File.join(root, "b.bluebook"), second)
    File.write(File.join(root, "a.bluebook"), first)
    File.write(File.join(root, "other.bluebook"), "Hecks.bluebook \"Other\" do\n  vision \"not part of Shaped\"\nend\n")
    [first, second]
  end

  def quality_control_source
    File.read(File.join(InMemoryDomain::ROOT, "lib/hecks/quality_control/quality_control.bluebook"), encoding: "UTF-8")
  end

  it "reads source containing non-ASCII bytes even when the process default external encoding is US-ASCII" do
    # An em-dash in a .bluebook comment raised ArgumentError under us-ASCII.
    source = "Hecks.bluebook \"Shaped\" do\n  vision \"an em dash — right here\"\nend\n"
    File.write(File.join(root, "a.bluebook"), source, encoding: "UTF-8")

    with_us_ascii_default_encoding { expect(source_text_for("Shaped", root)).to eq(source) }
  end

  it "snapshots every concept file for one chapter, in deterministic order" do
    first, second = write_chapter_files

    expect(source_text_for("Shaped", root)).to eq("#{first}\n#{second}")
  end

  # A domain that attaches a chapter the gem carries (the QA ledger, QualityControl) holds no
  # file for it: the era reads the chapter's own files, wherever the gem keeps them.
  it "reads an attached chapter's source from the files the gem carries it in" do
    File.write(File.join(root, "quality_control.hecksagon"), "# wiring only\n")

    expect(source_text_for("QualityControl", root)).to eq(quality_control_source)
  end

  it "holds nothing for an adapter that has no eras, and never refuses its drift", :aggregate_failures do
    check!(root, ERA_V1)
    expect(Dir.exist?(File.join(root, "data", "eras"))).to be(false)

    # the shape moves twice without refusal: Memory has no translation to apply
    expect { check!(root, ERA_DRIFTED) }.not_to raise_error
    expect { check!(root, ERA_BEHAVIOR_ONLY) }.not_to raise_error
    expect(Dir.exist?(File.join(root, "data", "eras"))).to be(false)
  end

  it "refuses a compute rule per-rule and by name on any non-Postgres adapter" do
    expect { check!(root, ERA_V1, translation_source: ERA_COMPUTE_TRANSLATION) }
      .to raise_error(Hecks::Runtime::WiringError, "compute rules require the Postgres adapter; Account is bound to Memory")
  end

  it "cosmetic edits (comments, whitespace) still project to the minted era name" do
    expect(guard(text: ERA_COSMETIC, stored_hash: minted_hash)).to eq(:cosmetic)
  end

  it "a shape edit would retroactively redefine era 1 — no --accept gets past this" do
    expect { guard(text: ERA_DRIFTED, stored_hash: minted_hash) }
      .to raise_error(Hecks::Runtime::WiringError,
                      /the edit changed the era's SHAPE, not just its text.*retroactively redefine what era 1 meant/m)
  end

  # A plain syntax error, not a meta-domain rule: shadow_parse's grammar must not
  # refuse frozen era texts that boot.
  it "unloadable text is not attestable at all" do
    expect { guard(text: ERA_BROKEN, stored_hash: minted_hash) }
      .to raise_error(Hecks::Runtime::WiringError, /does not load as a bluebook/)
  end

  it "an era that was never named cannot be shape-checked — reported, not refused" do
    expect(guard(text: ERA_DRIFTED, stored_hash: nil)).to eq(:unnamed)
  end

  # A hash minted under a different canonical form does not match a recomputation, so
  # the projection comparison must win or cosmetic edits to an old-form era false-refuse.
  it "prefers a matching stored projection over a stored_hash minted under a different canonical form" do
    expect(guard(text: ERA_COSMETIC, stored_hash: ERA_WRONG_FORM_HASH, stored_projection: shaped_projection(root)))
      .to eq(:cosmetic)
  end

  it "a real shape change still refuses under stored_projection, judged structurally" do
    expect { guard(text: ERA_DRIFTED, stored_hash: ERA_WRONG_FORM_HASH, stored_projection: shaped_projection(root)) }
      .to raise_error(Hecks::Runtime::WiringError,
                      /no longer projects to the shape frozen for era 1.*retroactively redefine what era 1 meant/m)
  end

  describe "the shape verdict `Era.Permit`'s givens hold, which never raises" do
    it "answers every way an edited text can stand against a frozen projection", :aggregate_failures do
      projection = shaped_projection(root)

      expect(verdict(ERA_COSMETIC, stored_projection: projection)).to eq(:cosmetic)
      expect(verdict(ERA_DRIFTED, stored_projection: projection)).to eq(:changed)
      expect(verdict(ERA_BROKEN, stored_projection: projection)).to eq(:unloadable)
    end

    it "answers every way an edited text can stand against a frozen hash", :aggregate_failures do
      stored_hash = minted_hash

      expect(verdict(ERA_COSMETIC, stored_hash: stored_hash)).to eq(:cosmetic)
      expect(verdict(ERA_DRIFTED, stored_hash: stored_hash)).to eq(:changed)
    end

    it "answers :unnamed when nothing was frozen to stand against" do
      expect(verdict(ERA_COSMETIC)).to eq(:unnamed)
    end

    it "is what shape_guard! raises on: the same words for a hash-named era" do
      stored_hash = minted_hash
      label = Hecks::Runtime::StorageShape::LABEL_LENGTH

      expect { guard(text: ERA_DRIFTED, stored_hash: stored_hash) }
        .to raise_error(Hecks::Runtime::WiringError,
                        /its name #{stored_hash[0, label]} was minted from a different shape.*retroactively redefine/m)
    end
  end

  it "a stored projection lets an UNNAMED era be shape-checked, not just shrugged at" do
    expect(guard(text: ERA_COSMETIC, stored_hash: nil, stored_projection: shaped_projection(root)))
      .to eq(:cosmetic)
  end
end
