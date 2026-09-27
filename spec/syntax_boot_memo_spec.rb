require "spec_helper"

# `SyntaxBoot.call` memoizes its ~0.76s grammar boot; these examples pin when the memo may answer.
# It is keyed by identity on the grammar registry's chapter set, the exact inputs `boot` reads.
RSpec.describe "SyntaxBoot's memo" do
  SyntaxBootUnderTest = Hecks::Bluebook::MetaValidator::SyntaxBoot
  MetaValidatorUnderTest = Hecks::Bluebook::MetaValidator

  # Disk cache off: it is keyed on chapter names and file content, so it would serve the reverted
  # state in the second example, which must prove the in-memory memo's identity boundary.
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

  # One global registry mutated twice (a chapter joins, then leaves) to prove both edges re-boot;
  # splitting would duplicate the dance or leave the shared registry dirty.
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

  # Regression pin: a cold registry build asks for the syntax table once per distinct chapter set
  # (raw load, one swap per language chapter, Paging attaching); one boot each is all a cache needs.
  it "boots at most once per distinct chapter set while the grammar registry builds itself from cold" do
    boots = 0
    allow(SyntaxBootUnderTest).to(receive(:boot).and_wrap_original do |m, *args|
      boots += 1
      m.call(*args)
    end)

    # Restored, not just reset: `@grammar_registry` is process-global, and a rebuilt one would skew
    # golden-fixture specs sharing the process (ir_golden_spec.rb).
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
