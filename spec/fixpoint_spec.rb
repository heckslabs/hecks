
require "spec_helper"
require "tmpdir"

# The language passes its own rules.
#
# `lib/hecksagain/language/bluebook.bluebook` declares what a bluebook is, and
# nine rules are now enforced there and nowhere else. It is itself a bluebook —
# so it must satisfy the rules it declares, or the language demands of every
# domain something its own definition does not do.
#
# Load-time validation skips it (judging it while loading it would recurse), so
# without this the one bluebook that most needs to obey the rules would be the
# only one exempt from them.
RSpec.describe "the language's own definition" do
  def meta = Hecksagain::Bluebook::MetaValidator.grammar_registry.bluebook("Meta")

  it "is judged by the rules it declares, and passes" do
    refusals = Hecksagain::Bluebook::MetaValidator::Judge.new(meta).refusals

    expect(refusals).to be_empty
  end

  it "declares the shapes a bluebook is made of" do
    # if the language stops describing a category, a bluebook using it stops
    # being judged — silently, since the judge skips what it has no shape for
    expect(meta.aggregates.map(&:name)).to include(
      "Chapter", "Root", "Verb", "Shape", "Ask", "Piece", "Member",
      "Reaction", "Saga", "Projection", "Vocabulary"
    )
  end

  it "is what actually refuses a malformed bluebook, end to end" do
    # A rule declared but never dispatched cannot fire — five sat in that state
    # after the first pass. So this goes through the real load path rather than
    # calling the judge directly : `emits ""` has no `raise` left in any builder,
    # and is refused only because the language says so.
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "silent.bluebook"), <<~BLUEBOOK)
        Hecks.bluebook "Silent" do
          vision "a command that announces nothing in particular"
          supporting

          aggregate "Thing" do
            description "a thing"
            attribute :label, Label

            value_object "Label" do
              attribute :value, String
            end

            command "Make" do
              role "Someone"
              goal "make a thing"
              attribute :label, Label
              emits ""
            end
          end
        end
      BLUEBOOK

      expect { Hecks.boot(dir) }
        .to raise_error(Hecksagain::Bluebook::DSL::Malformed, /an event is named/)
    end
  end
end
