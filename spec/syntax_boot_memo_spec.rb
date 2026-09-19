require "spec_helper"

# `SyntaxBoot.call` dispatches the language's own ~284-row grammar table
# into a live "Bluebook" runtime — real work, ~0.76s — and memoizes the
# result. What this file pins is when that memo is allowed to answer.
#
# The previous guard cached nothing until `grammar_registry_ready?`, i.e.
# until the grammar registry had finished judging itself and attaching
# Paging. Right hazard (a snapshot taken before Paging attached is missing
# limit/offset/cursor/nulls), wrong cure: every `word_gate_dispatch` that
# landed inside that window re-ran the whole boot. Measured at 42 boots
# and 32 of a 35-second `Hecks.boot` — 95% of booting any domain, spent
# re-deriving the same table from the same chapters.
#
# The cache is now keyed on the grammar registry's chapter set, by
# identity — the exact inputs `boot` reads — so it is served precisely
# while those inputs are unchanged and never otherwise. Three facts:
#
# Disk cache off for this whole file. `SyntaxBoot` also persists its
# result to disk across processes, keyed on chapter names (not object
# identity — a different process has no way to compare identity) plus a
# content hash of the grammar files on disk. That is a coarser, correctly
# content-addressed cache: two structurally-identical inputs, even
# encountered at different moments, legitimately share one answer. This
# file's own "boots again... and again once it leaves" example below
# deliberately reverts the chapter name list to an earlier state within
# one process (add a throwaway chapter, then remove it) specifically to
# pin the in-memory memo's object-identity boundary — a real re-boot on
# any identity change, never mind whether the reverted content happens to
# match something already seen. The disk cache would otherwise correctly
# serve that reverted, byte-identical state from what example 1 already
# wrote, which is right for the disk cache's own contract and wrong for
# what this file exists to prove. `stack-restore shaped`, same reasoning
# `MetaValidator.while_disabled` already uses for its own toggle.
RSpec.describe "SyntaxBoot's memo" do
  SyntaxBootUnderTest = Hecks::Bluebook::MetaValidator::SyntaxBoot
  MetaValidatorUnderTest = Hecks::Bluebook::MetaValidator

  around do |example|
    previous = ENV.fetch("HECKS_SYNTAX_BOOT_CACHE", nil)
    ENV["HECKS_SYNTAX_BOOT_CACHE"] = "off"
    example.run
  ensure
    ENV["HECKS_SYNTAX_BOOT_CACHE"] = previous
  end

  it "answers from the cache while the grammar registry's chapters are unchanged" do
    first = SyntaxBootUnderTest.call

    expect(SyntaxBootUnderTest).not_to receive(:boot)
    expect(SyntaxBootUnderTest.call).to be(first)
  end

  # One process-global grammar registry mutated twice (a chapter joins,
  # then leaves via ensure) proving the memo re-boots on both edges;
  # splitting would mean duplicating the add/remove dance across
  # examples or risking the shared global registry left dirty between
  # them.
  # rubocop:disable-next RSpec/ExampleLength
  it "boots again the moment a chapter joins the registry, and again once it leaves" do
    registry = MetaValidatorUnderTest.grammar_registry
    SyntaxBootUnderTest.call
    before = registry.bluebooks.keys

    begin
      Hecks.with_registry(registry) do
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

  # **The measured bug, pinned**. Building the grammar registry from cold
  # walks through a handful of distinct chapter sets — the raw load, then
  # one replacement per language chapter as the fixpoint judge swaps each
  # raw chapter for its assembled self, then Paging attaching — and every
  # `word_gate_dispatch` inside that build asks for the syntax table. One
  # boot per distinct chapter set is the most a correct cache can need;
  # the old guard did 42.
  it "boots at most once per distinct chapter set while the grammar registry builds itself from cold" do
    boots = 0
    allow(SyntaxBootUnderTest).to(receive(:boot).and_wrap_original do |m, *args|
      boots += 1
      m.call(*args)
    end)

    # Saved and restored, not just reset — @grammar_registry is process-
    # global and memoized. Left nil'd-then-rebuilt with no restore, a
    # golden-fixture spec sharing this process later (ir_golden_spec.rb)
    # would compare against a registry built at this moment in suite
    # history instead of the pristine one its fixture was captured
    # against — the exact intermittent parallel_rspec-only flake this
    # file's own sibling test (fixpoint_spec.rb) was found doing the same
    # unguarded reset for.
    original_registry = MetaValidatorUnderTest.instance_variable_get(:@grammar_registry)
    original_ready_for = MetaValidatorUnderTest.instance_variable_get(:@grammar_ready_for)

    begin
      MetaValidatorUnderTest.instance_variable_set(:@grammar_registry, nil)
      registry = MetaValidatorUnderTest.grammar_registry

      attached = registry.bluebooks.values.count { |chapter| chapter.attaches_to.any? }
      distinct_chapter_sets = 1 + MetaValidatorUnderTest::LANGUAGE_CHAPTERS.size + attached
      expect(boots).to be <= distinct_chapter_sets
      expect(boots).to be < 42
    ensure
      MetaValidatorUnderTest.instance_variable_set(:@grammar_registry, original_registry)
      MetaValidatorUnderTest.instance_variable_set(:@grammar_ready_for, original_ready_for)
    end
  end
end
