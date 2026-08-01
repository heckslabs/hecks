
require "spec_helper"

# Every corpus member must LOAD.
#
# `bin/parity` is the only thing that reads the corpus, and it is hand-run —
# so a bluebook could stop parsing entirely and the suite people actually run
# would stay green. That happened: a new value-object rule landed, banking and
# pizzas were migrated to satisfy it, and `lib/hecksagain/grammar/expression.bluebook`
# was left behind. It raised `Malformed` at load, parity died before stage one,
# and rspec reported 358/358 the whole time — because nothing in spec/ booted
# the grammar chapter.
#
# This walks the SAME corpus `bin/parity` walks, derived the same way rather
# than listed, so a member added there is covered here without anyone
# remembering to add it: every example directory, plus every grammar chapter
# (`lib/hecksagain/grammar/*.bluebook`) individually — parity stages each
# chapter alone, so a second chapter beside expression.bluebook is a corpus
# member in its own right, not a file the `head -1` of an earlier walk
# silently skipped.
RSpec.describe "The corpus" do
  # Mirrors bin/parity's bluebook lookup for example directories — prefer
  # <domain>/bluebook/*.bluebook, fall back to <domain>/*.bluebook.
  def self.bluebook_in(domain)
    Dir.glob(File.join(domain, "bluebook", "*.bluebook")).sort.first ||
      Dir.glob(File.join(domain, "*.bluebook")).sort.first
  end

  EXAMPLE_ROOTS = Dir.glob(File.join(InMemoryDomain::ROOT, "examples", "*"))
                     .select { |path| File.directory?(path) }.sort.freeze

  GRAMMAR_CHAPTERS = Dir.glob(File.join(InMemoryDomain::ROOT, "lib/hecksagain/grammar", "*.bluebook")).sort.freeze

  # [parity-script stem, bluebook path] — examples are named after their
  # directory, grammar chapters after their own file.
  CORPUS_MEMBERS = (
    EXAMPLE_ROOTS.map { |domain| [File.basename(domain), bluebook_in(domain)] } +
    GRAMMAR_CHAPTERS.map { |chapter| [File.basename(chapter, ".bluebook"), chapter] }
  ).freeze

  it "finds every domain bin/parity walks" do
    expect(EXAMPLE_ROOTS).not_to be_empty
    expect(GRAMMAR_CHAPTERS).not_to be_empty
    expect(CORPUS_MEMBERS.map(&:last)).to all(be_truthy)
  end

  it "gives every corpus member a parity script" do
    CORPUS_MEMBERS.each do |stem, bluebook|
      script = File.join(InMemoryDomain::ROOT, "spec", "parity", "#{stem}.json")
      expect(File).to exist(script), "no parity script for #{bluebook} — expected #{script}"
    end
  end

  CORPUS_MEMBERS.each do |_stem, bluebook|
    next unless bluebook

    it "loads #{File.basename(bluebook)}" do
      registry = Hecksagain::Runtime::Registry.new

      expect do
        Hecksagain.with_registry(registry) do
          Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
          Kernel.load(InMemoryDomain::EXTRACTION_PORT)
          Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
          Kernel.load(InMemoryDomain::PRISM_ADAPTER)
          Kernel.load(bluebook)
        end
      end.not_to raise_error

      expect(registry.bluebooks).not_to be_empty
    end
  end
end
