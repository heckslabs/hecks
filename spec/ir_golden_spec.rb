require "spec_helper"
require "json"
require "fileutils"

# Freezes `Bluebook#to_h`, the wire format behind era hashes (StorageShape) and the MetaValidator
# cache key. round_trip_spec compares two live computations, so a shared emission bug passes there.
# Regenerate with GOLDEN=rewrite only when the wire format really changed; read the diff first.
RSpec.describe "the IR the builder produces, frozen" do
  GOLDEN_DIR = File.join(InMemoryDomain::ROOT, "spec/golden/ir").freeze

  # The Gemfile pins `json` exactly because newer versions reformat empty arrays/hashes in
  # pretty_generate, which would fail every fixture with diffs unrelated to the IR.
  PIN_MISSING_MESSAGE = "Gemfile no longer pins `json` to an exact version — " \
                        "the golden fixtures below need that pin to stay pretty-printed identically".freeze

  def gemfile_json_pin
    File.read(File.join(InMemoryDomain::ROOT, "Gemfile")).match(/^\s*gem\s+"json"\s*,\s*"([\d.]+)"\s*$/)&.captures&.first
  end

  def pin_mismatch_message(pin)
    "installed `json` gem (#{JSON::VERSION}) does not match the Gemfile's pin " \
      "(#{pin}) — run `bundle install` (or check for a stray `bundle config " \
      "disable_local_branch_check`/frozen-lockfile override) before trusting any " \
      "failure below, since a mismatched `json` gem reformats JSON.pretty_generate " \
      "output and fails every fixture here for reasons unrelated to the IR itself"
  end

  it "resolves the exact `json` gem the Gemfile pins, not merely one the lockfile once recorded", :aggregate_failures do
    pin = gemfile_json_pin

    expect(pin).not_to be_nil, PIN_MISSING_MESSAGE
    expect(JSON::VERSION).to eq(pin), pin_mismatch_message(pin)
  end

  # Chapters that load from a file, name => path.
  LOADABLE = {
    "Pizzas"     => "examples/pizzas/bluebook/pizzas.bluebook",
    # Composite identity, a command that announces twice, two entities on one head, a second
    # read_model and process_manager: the rare forms the coverage gates exist to catch.
    "Banking"    => InMemoryDomain::BANKING_BLUEBOOK_DIR,
    "Expression" => "lib/hecks/grammar/expression.bluebook",
    "TillRoom"   => "spec/fixtures/till.bluebook",
    "Wire"       => "spec/fixtures/settlement.bluebook",
    "Reflex"     => "spec/fixtures/reflex.bluebook",
    # The first chapter to declare `namespace`, so the golden corpus carries that field set.
    "Hecks"      => "lib/hecks/hecks/hecks.bluebook"
  }.freeze

  # Language chapters come from the bootstrap registry: judging one while loading it would recurse.
  LANGUAGES = %w[Bluebook World Hecksagon].freeze

  def load_chapter(file)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      path = File.absolute_path(file, InMemoryDomain::ROOT)
      load_bluebook_files(path)
    end
    registry
  end

  def golden_path(name) = File.join(GOLDEN_DIR, "#{name}.json")

  # Sorted like hecks canonicalise (key order is not semantics), so a diff names the moved field.
  def rendered(bluebook) = "#{JSON.pretty_generate(sorted(bluebook.to_h))}\n"

  def sorted(value)
    case value
    when Hash  then value.sort_by { |key, _| key.to_s }.to_h { |key, held| [key.to_s, sorted(held)] }
    when Array then value.map { |held| sorted(held) }
    when Symbol then value.to_s
    else value
    end
  end

  def expect_frozen_ir(name, bluebook)
    actual = rendered(bluebook)

    if ENV["GOLDEN"] == "rewrite"
      FileUtils.mkdir_p(GOLDEN_DIR)
      File.write(golden_path(name), actual)
      skip "rewrote #{name}.json"
    end

    expect(File.exist?(golden_path(name)))
      .to be(true), "no frozen IR for #{name} — run GOLDEN=rewrite to record it"
    expect(actual).to eq(File.read(golden_path(name)))
  end

  LOADABLE.each do |name, file|
    it "#{name} matches its frozen IR" do
      expect_frozen_ir(name, load_chapter(file).bluebook(name))
    end
  end

  LANGUAGES.each do |name|
    it "#{name}, the language itself, matches its frozen IR" do
      expect_frozen_ir(name, Hecks::Bluebook::MetaValidator.grammar_registry.bluebook(name))
    end
  end
end
