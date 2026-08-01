
require "spec_helper"
require "tmpdir"

# The language passes its own rules — and RUNS from its own records.
#
# `lib/hecksagain/language/bluebook/` declares what a bluebook is, and
# nine rules are now enforced there and nowhere else. It is itself a bluebook —
# so it must satisfy the rules it declares, or the language demands of every
# domain something its own definition does not do.
#
# The bootstrap loads it raw (judging it while loading it would recurse), but
# the exemption ends there : `grammar_registry` immediately judges the merged
# chapter through itself and keeps the ASSEMBLED graph, so the language every
# other bluebook is judged by is the one the language itself produced. The
# first example below is the independent proof the judge accepts the chapter (every
# other path is a verdicts-cache hit after boot) ; the last two prove the
# fixpoint is load-bearing, not merely possible.
RSpec.describe "the language's own definition" do
  def meta = Hecksagain::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")

  it "is judged by the rules it declares, and passes" do
    refusals = Hecksagain::Bluebook::MetaValidator::Judge.new(meta).refusals

    expect(refusals).to be_empty
  end

  it "declares the shapes a bluebook is made of" do
    # if the language stops describing a category, a bluebook using it stops
    # being judged — silently, since the judge skips what it has no shape for
    expect(meta.aggregates.map(&:name)).to include(
      "Bluebook", "Aggregate", "Command", "ValueObject", "Query", "Entity", "Member",
      "Policy", "ProcessManager", "ReadModel", "Vocabulary"
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

  # THE FIXPOINT IS LOAD-BEARING. The registry's language chapters are the
  # graphs the language assembled from its own records — not the raw builder
  # output — and nothing was lost on the way through.
  #
  # The door-coherence example resets the singleton and binds fresh,
  # deliberately : any spec that binds another runtime repoints the global
  # constants at ITS surface, so "registry and door agree" is only a fact
  # about the moment just after a bind — which is exactly the moment this
  # asserts, whatever order the suite ran in.
  it "runs from its own records — registry and the installed door agree from bind" do
    Hecksagain::Bluebook::MetaValidator.instance_variable_set(:@grammar_registry, nil)
    registry = Hecksagain::Bluebook::MetaValidator.grammar_registry
    Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))

    expect(Object.const_get(:Bluebook).const_get(:Aggregate).ir)
      .to be(registry.bluebook("Bluebook").aggregate("Aggregate"))
    expect(Object.const_get(:World).const_get(:World).ir)
      .to be(registry.bluebook("World").aggregate("World"))
  end

  it "lost nothing on the way through — assembled equals a fresh raw load, chapter for chapter" do
    registry = Hecksagain::Bluebook::MetaValidator.grammar_registry
    raw = Hecksagain::Bluebook::MetaValidator.load_grammar_into(Hecksagain::Runtime::Registry.new)

    Hecksagain::Bluebook::MetaValidator::LANGUAGE_CHAPTERS.each do |name|
      expect(registry.bluebook(name).to_h).to eq(raw.bluebook(name).to_h)
    end
  end
end
