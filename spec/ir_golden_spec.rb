require "spec_helper"
require "json"
require "fileutils"

# `Bluebook#to_h` IS the wire format two production mechanisms stand on:
# `StorageShape.project` reads it by key name to mint era hashes and detect
# drift (a silently renamed or dropped key would corrupt era identity with no
# error anywhere), and `MetaValidator` hashes it as the verdict-cache key. So
# it is the one shape in this codebase that must never move by accident.
#
# `round_trip_spec` cannot hold it still. It compares the builder's IR against
# the meta-domain's records — two sides BOTH computed fresh at test time, so
# an emission bug on a path the corpus never exercises is simply absent from
# both and passes vacuously. `Field#default` was legal and unexercised for
# precisely that reason. A frozen file is the one check immune to correlated
# drift: it pins today's emission against a reference nothing live can move.
#
# The corpus is every chapter in the tree, not the four `round_trip_spec`
# walks: a shape only one bluebook exercises is exactly the shape a partial
# corpus lets through.
#
# Regenerate deliberately, never casually:
#
#     GOLDEN=rewrite bundle exec rspec spec/ir_golden_spec.rb
#
# A rewrite is a claim that the wire format CHANGED — read the diff before
# trusting it, because every held era's projection was minted off the old one.
RSpec.describe "the IR the builder produces, frozen" do
  GOLDEN_DIR = File.join(InMemoryDomain::ROOT, "spec/golden/ir").freeze

  # Chapters that load from a file, name => path.
  LOADABLE = {
    "Pizzas"     => "examples/pizzas/bluebook/pizzas.bluebook",
    # THE FLAGSHIP DOMAIN, CARRYING WHAT MARKET AND RELAY USED TO ALONE.
    # Composite identity (`SafeDepositBox`, branch_code + box_number), a
    # command that announces twice (`Surrender`), two entities on one head,
    # a second read_model and a second process_manager — every rare form this
    # corpus's coverage gates exist to catch, now exercised by the real
    # domain rather than a fixture invented solely to hold it.
    "Banking"    => "examples/banking/bluebook/banking.bluebook",
    "Expression" => "lib/hecksagain/grammar/expression.bluebook",
    "TillRoom"   => "spec/fixtures/till.bluebook",
    "Wire"       => "spec/fixtures/settlement.bluebook",
    "Reflex"     => "spec/fixtures/reflex.bluebook"
  }.freeze

  # The two LANGUAGE chapters are not loaded like a domain — judging one while
  # loading it would recurse, so they come from the bootstrap registry. They are
  # in the corpus because the refactor changes how every chapter is built, and
  # the language is the chapter it would be worst to break quietly.
  LANGUAGES = %w[Bluebook World Hecksagon].freeze

  def load_chapter(file)
    registry = Hecksagain::Runtime::Registry.new
    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.join(InMemoryDomain::ROOT, file))
    end
    registry
  end

  def golden_path(name) = File.join(GOLDEN_DIR, "#{name}.json")

  # Pretty-printed and key-sorted, so a diff a human reads names the field that
  # moved rather than the whole document. Sorting is the same normalisation
  # `bin/canonicalise` applies — key order is not semantics.
  def rendered(bluebook) = "#{JSON.pretty_generate(sorted(bluebook.to_h))}\n"

  def sorted(value)
    case value
    when Hash  then value.sort_by { |key, _| key.to_s }.to_h { |key, held| [key.to_s, sorted(held)] }
    when Array then value.map { |held| sorted(held) }
    when Symbol then value.to_s
    else value
    end
  end

  def compare(name, bluebook)
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
      compare(name, load_chapter(file).bluebook(name))
    end
  end

  LANGUAGES.each do |name|
    it "#{name}, the language itself, matches its frozen IR" do
      compare(name, Hecksagain::Bluebook::MetaValidator.grammar_registry.bluebook(name))
    end
  end
end
