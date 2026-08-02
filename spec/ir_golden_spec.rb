
require "spec_helper"
require "json"
require "fileutils"

# THE DIFF TARGET FOR THE REFACTOR THAT MAKES THE BUILDERS OUTPUT CLASSES.
#
# `Bluebook#to_h` is a byte-for-byte contract with the Rust parser — `bin/ir`
# feeds `bin/parity`, and both sides are canonicalised and diffed. It is also
# the `MetaValidator` verdict-cache key. So it is the one shape in this codebase
# that must survive a rewrite of everything behind it UNCHANGED.
#
# `round_trip_spec` cannot play that role. It compares the builder's IR against
# the meta-domain's records — and the refactor CONSUMES one of those two sides,
# so the comparator dies exactly when it would be needed most. This spec holds
# the answer as a FROZEN FILE instead, produced by the builder as it stands
# today, which nothing downstream of the refactor can have influenced.
#
# The corpus is every chapter in the tree, not the four `round_trip_spec` walks:
# a shape only one bluebook exercises is exactly the shape a partial corpus lets
# through. `Field#default` was legal and unexercised for precisely that reason.
#
# Regenerate deliberately, never casually:
#
#     GOLDEN=rewrite bundle exec rspec spec/ir_golden_spec.rb
#
# A rewrite is a claim that the wire format CHANGED. `bin/parity` is the second
# opinion — if the Rust side still agrees, the change was intended.
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
  # `bin/canonicalise` applies before parity diffs — key order is not semantics.
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
