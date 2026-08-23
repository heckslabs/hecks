require "spec_helper"

# `SyntaxBoot.call` dispatches the language's own ~284-row grammar table
# into a live "Bluebook" runtime — real work, ~0.76s — and memoizes the
# result. What this file pins is WHEN that memo is allowed to answer.
#
# The previous guard cached nothing until `grammar_registry_ready?`, i.e.
# until the grammar registry had finished judging itself and attaching
# Paging. Right hazard (a snapshot taken before Paging attached is missing
# limit/offset/cursor/nulls), wrong cure: every `word_gate_dispatch` that
# landed inside that window re-ran the whole boot. Measured at 42 boots
# and 32 of a 35-second `Hecks.boot` — 95% of booting ANY domain, spent
# re-deriving the same table from the same chapters.
#
# The cache is now keyed on the grammar registry's chapter set, by
# identity — the exact inputs `boot` reads — so it is served precisely
# while those inputs are unchanged and never otherwise. Three facts:
RSpec.describe "SyntaxBoot's memo" do
  SyntaxBootUnderTest = Hecksagain::Bluebook::MetaValidator::SyntaxBoot
  MetaValidatorUnderTest = Hecksagain::Bluebook::MetaValidator

  it "answers from the cache while the grammar registry's chapters are unchanged" do
    first = SyntaxBootUnderTest.call

    expect(SyntaxBootUnderTest).not_to receive(:boot)
    expect(SyntaxBootUnderTest.call).to be(first)
  end

  it "boots again the moment a chapter joins the registry, and again once it leaves" do
    registry = MetaValidatorUnderTest.grammar_registry
    SyntaxBootUnderTest.call
    before = registry.bluebooks.keys

    begin
      Hecksagain.with_registry(registry) do
        Hecks.bluebook "SyntaxBootMemoProbe" do
          vision "a throwaway chapter, added only to prove the syntax table's own memo notices a new chapter"
          supporting

          aggregate "Probe" do
            description "nothing — exists so the chapter is well-formed"

            attribute :name, ProbeName
            identified_by :name

            value_object "ProbeName" do
              attribute :value, String
            end
          end
        end
      end
      expect(registry.bluebooks.keys - before).to eq(["SyntaxBootMemoProbe"])

      expect(SyntaxBootUnderTest).to receive(:boot).once.and_call_original
      SyntaxBootUnderTest.call
    ensure
      registry.bluebooks.delete("SyntaxBootMemoProbe")
    end

    expect(SyntaxBootUnderTest).to receive(:boot).once.and_call_original
    SyntaxBootUnderTest.call
  end

  # THE MEASURED BUG, PINNED. Building the grammar registry from cold
  # walks through a handful of distinct chapter sets — the raw load, then
  # one replacement per language chapter as the fixpoint judge swaps each
  # raw chapter for its assembled self, then Paging attaching — and every
  # `word_gate_dispatch` inside that build asks for the syntax table. One
  # boot per DISTINCT chapter set is the most a correct cache can need;
  # the old guard did 42.
  it "boots at most once per distinct chapter set while the grammar registry builds itself from cold" do
    boots = 0
    allow(SyntaxBootUnderTest).to(receive(:boot).and_wrap_original { |m, *args|
      boots += 1
      m.call(*args)
    })

    MetaValidatorUnderTest.instance_variable_set(:@grammar_registry, nil)
    registry = MetaValidatorUnderTest.grammar_registry

    attached = registry.bluebooks.values.count { |chapter| chapter.attaches_to.any? }
    distinct_chapter_sets = 1 + MetaValidatorUnderTest::LANGUAGE_CHAPTERS.size + attached
    expect(boots).to be <= distinct_chapter_sets
    expect(boots).to be < 42
  end
end
