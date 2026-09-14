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
#
# The per-member LOAD itself is proven by spec/model_check_spec.rb's
# "the real corpus" walk, which boots a superset of these members (plus
# qa/bluebook) and raises on a member that fails to load or registers no
# bluebook. This file keeps what that walk does not check: that the
# derived member list is non-empty and every member has a corpus script.
RSpec.describe "The corpus" do
  # Read from Hecks::Corpus, the one table every corpus walk shares.
  # Example domains are loaded by folder, so adding or regrouping a concept
  # file never requires a corpus catalog change; grammar chapters and
  # framework members are flat sibling files, one chapter each.
  EXAMPLE_ROOTS = Hecks::Corpus.members(:example).map(&:path).freeze
  GRAMMAR_CHAPTERS = Hecks::Corpus.members(:grammar).map(&:path).freeze
  FRAMEWORK_MEMBERS = Hecks::Corpus.members(:framework).map(&:path).freeze

  # [corpus-script stem, bluebook path] — examples are named after their
  # directory, grammar chapters and framework members after their own file.
  CORPUS_MEMBERS = Hecks::Corpus.members(:example, :grammar, :framework)
                                .map { |member| [member.stem, Hecks::Corpus.source_of(member)] }.freeze

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
end
