require "spec_helper"

# Every corpus member must LOAD.
#
# The corpus was once read only by a hand-run script —
# so a bluebook could stop parsing entirely and the suite people actually run
# would stay green. That happened: a new value-object rule landed, banking and
# pizzas were migrated to satisfy it, and `lib/hecks/grammar/expression.bluebook`
# was left behind. It raised `Malformed` at load, the hand-run walk died at its
# first stage, and rspec reported 358/358 the whole time — because nothing in
# spec/ booted the grammar chapter.
#
# This walks the corpus derived the same way rather
# than listed, so a member added there is covered here without anyone
# remembering to add it: every example directory, plus every grammar chapter
# (`lib/hecks/grammar/*.bluebook`) individually — each
# chapter loads alone, so a second chapter beside expression.bluebook is a corpus
# member in its own right, not a file the `head -1` of an earlier walk
# silently skipped.
RSpec.describe "The corpus" do
  # Example domains are loaded by folder, so adding or regrouping a concept
  # file never requires a corpus catalog change.
  def self.bluebook_in(domain)
    nested = File.join(domain, "bluebook")
    return nested if Dir.glob(File.join(nested, "*.bluebook")).any?

    domain if Dir.glob(File.join(domain, "*.bluebook")).any?
  end

  EXAMPLE_ROOTS = Dir.glob(File.join(InMemoryDomain::ROOT, "examples", "*"))
                     .select { |path| File.directory?(path) }.sort.freeze

  GRAMMAR_CHAPTERS = Dir.glob(File.join(InMemoryDomain::ROOT, "lib/hecks/grammar", "*.bluebook")).freeze

  # `lib/hecks/framework/bluebook/` holds framework-level domains (Governance, and
  # whatever else lands beside it) as flat sibling files, the same shape
  # GRAMMAR_CHAPTERS already walks — not one directory per domain like
  # `examples/`, since these aren't teaching examples with their own
  # `bluebook/` subfolder each.
  FRAMEWORK_MEMBERS = Dir.glob(File.join(InMemoryDomain::ROOT, "lib/hecks/framework/bluebook", "*.bluebook")).freeze

  # [corpus-script stem, bluebook path] — examples are named after their
  # directory, grammar chapters and framework members after their own file.
  CORPUS_MEMBERS = (
    EXAMPLE_ROOTS.map { |domain| [File.basename(domain), bluebook_in(domain)] } +
    GRAMMAR_CHAPTERS.map { |chapter| [File.basename(chapter, ".bluebook"), chapter] } +
    FRAMEWORK_MEMBERS.map { |member| [File.basename(member, ".bluebook"), member] }
  ).freeze

  it "finds every domain the corpus declares" do
    expect(EXAMPLE_ROOTS).not_to be_empty
    expect(GRAMMAR_CHAPTERS).not_to be_empty
    expect(FRAMEWORK_MEMBERS).not_to be_empty
    expect(CORPUS_MEMBERS.map(&:last)).to all(be_truthy)
  end

  it "gives every corpus member a script" do
    CORPUS_MEMBERS.each do |stem, bluebook|
      script = File.join(InMemoryDomain::ROOT, "spec", "corpus", "#{stem}.json")
      expect(File).to exist(script), "no corpus script for #{bluebook} — expected #{script}"
    end
  end

  # CORPUS_MEMBERS is an Array of [stem, bluebook] pairs (see its own
  # definition above), not a Hash — Style/HashEachMethods' `.each_value`
  # rewrite assumed otherwise from the `|_stem, bluebook|` block shape
  # alone and raised NoMethodError at load time. False positive.
  # rubocop:disable-next Style/HashEachMethods
  CORPUS_MEMBERS.each do |_stem, bluebook|
    next unless bluebook

    it "loads #{File.basename(bluebook)}" do
      registry = Hecks::Runtime::Registry.new

      expect do
        Hecks.with_registry(registry) do
          Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
          Kernel.load(InMemoryDomain::EXTRACTION_PORT)
          Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
          Kernel.load(InMemoryDomain::PRISM_ADAPTER)
          load_bluebook_files(bluebook)
        end
      end.not_to raise_error

      expect(registry.bluebooks).not_to be_empty
    end
  end
end
