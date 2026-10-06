require "spec_helper"

# `SyntaxBoot.call` memoizes its ~0.76s grammar boot; these examples pin when the memo may answer.
# It is keyed by identity on the grammar registry's chapter set, the exact inputs `boot` reads.
RSpec.describe "SyntaxBoot's memo" do
  SyntaxBootUnderTest = Hecks::Bluebook::MetaValidator::SyntaxBoot
  MetaValidatorUnderTest = Hecks::Bluebook::MetaValidator

  # A throwaway chapter, added only to prove the syntax table's own memo notices a new chapter.
  SYNTAX_BOOT_PROBE_CHAPTER = proc do
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

  # Disk cache off: it is keyed on chapter names and file content, so it would serve the reverted
  # state in the second example, which must prove the in-memory memo's identity boundary.
  around do |example|
    previous = ENV.fetch("HECKS_SYNTAX_BOOT_CACHE", nil)
    ENV["HECKS_SYNTAX_BOOT_CACHE"] = "off"
    example.run
  ensure
    ENV["HECKS_SYNTAX_BOOT_CACHE"] = previous
  end

  it "answers from the cache while the grammar registry's chapters are unchanged", :aggregate_failures do
    first = SyntaxBootUnderTest.call
    allow(SyntaxBootUnderTest).to receive(:boot).and_call_original

    expect(SyntaxBootUnderTest.call).to be(first)
    expect(SyntaxBootUnderTest).not_to have_received(:boot)
  end

  # One global registry mutated twice (a chapter joins, then leaves) to prove both edges re-boot.
  # The chapter is gone again when the block returns.
  def with_probe_chapter(registry)
    before = registry.bluebooks.keys
    Hecks.with_registry(registry) { Hecks.bluebook("SyntaxBootMemoProbe", &SYNTAX_BOOT_PROBE_CHAPTER) }
    expect(registry.bluebooks.keys - before).to eq(["SyntaxBootMemoProbe"])
    yield
  ensure
    registry.bluebooks.delete("SyntaxBootMemoProbe")
  end

  def warmed_grammar_registry = MetaValidatorUnderTest.grammar_registry.tap { SyntaxBootUnderTest.call }

  # The probe chapter joins and leaves in one example: its aggregate is declared into the process-wide
  # grammar registry, which a second declaration of the same chapter would collide with.
  it "boots again the moment a chapter joins the registry, and again once it leaves" do
    registry = warmed_grammar_registry
    allow(SyntaxBootUnderTest).to receive(:boot).and_call_original
    with_probe_chapter(registry) { SyntaxBootUnderTest.call }
    SyntaxBootUnderTest.call

    expect(SyntaxBootUnderTest).to have_received(:boot).twice
  end

  # Counts the boots a spec triggers, in the `boots` of the hash it answers.
  def boot_counter
    counter = { boots: 0 }
    allow(SyntaxBootUnderTest).to(receive(:boot).and_wrap_original do |m, *args|
      counter[:boots] += 1
      m.call(*args)
    end)
    counter
  end

  # Restored, not just reset: `@grammar_registry` is process-global, and a rebuilt one would skew
  # golden-fixture specs sharing the process (ir_golden_spec.rb).
  def with_cold_grammar_registry
    original_registry = MetaValidatorUnderTest.instance_variable_get(:@grammar_registry)
    original_ready_for = MetaValidatorUnderTest.instance_variable_get(:@grammar_ready_for)
    MetaValidatorUnderTest.instance_variable_set(:@grammar_registry, nil)
    yield MetaValidatorUnderTest.grammar_registry
  ensure
    MetaValidatorUnderTest.instance_variable_set(:@grammar_registry, original_registry)
    MetaValidatorUnderTest.instance_variable_set(:@grammar_ready_for, original_ready_for)
  end

  def distinct_chapter_sets(registry)
    attached = registry.bluebooks.values.count { |chapter| chapter.attaches_to.any? }
    1 + MetaValidatorUnderTest::LANGUAGE_CHAPTERS.size + attached
  end

  # Regression pin: a cold registry build asks for the syntax table once per distinct chapter set
  # (raw load, one swap per language chapter, Paging attaching); one boot each is all a cache needs.
  it "boots at most once per distinct chapter set while the grammar registry builds itself from cold", :aggregate_failures do
    counter = boot_counter
    distinct = with_cold_grammar_registry { |registry| distinct_chapter_sets(registry) }

    expect(counter[:boots]).to be <= distinct
    expect(counter[:boots]).to be < 42
  end
end
