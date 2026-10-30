require "spec_helper"

# `SyntaxBoot.call` memoizes its ~0.76s grammar boot; these examples pin when the memo may answer.
# It is keyed by identity on the grammar registry's bluebook set, the exact inputs `boot` reads.
RSpec.describe "SyntaxBoot's memo" do
  SyntaxBootUnderTest = Hecks::Bluebook::MetaValidator::SyntaxBoot
  MetaValidatorUnderTest = Hecks::Bluebook::MetaValidator

  # A throwaway bluebook, added only to prove the syntax table's own memo notices a new bluebook.
  SYNTAX_BOOT_PROBE_BLUEBOOK = proc do
    vision "a throwaway bluebook, added only to prove the syntax table's own memo notices a new bluebook"
    supporting

    aggregate "Probe" do
      description "nothing — exists so the bluebook is well-formed"

      attribute :name, ProbeName
      identified_by :name

      value_object "ProbeName", String
    end
  end

  # Disk cache off: it is keyed on bluebook names and file content, so it would serve the reverted
  # state in the second example, which must prove the in-memory memo's identity boundary.
  around do |example|
    previous = ENV.fetch("HECKS_SYNTAX_BOOT_CACHE", nil)
    ENV["HECKS_SYNTAX_BOOT_CACHE"] = "off"
    example.run
  ensure
    ENV["HECKS_SYNTAX_BOOT_CACHE"] = previous
  end

  it "answers from the cache while the grammar registry's bluebooks are unchanged", :aggregate_failures do
    first = SyntaxBootUnderTest.call
    allow(SyntaxBootUnderTest).to receive(:boot).and_call_original

    expect(SyntaxBootUnderTest.call).to be(first)
    expect(SyntaxBootUnderTest).not_to have_received(:boot)
  end

  # One global registry mutated twice (a bluebook joins, then leaves) to prove both edges re-boot.
  # The bluebook is gone again when the block returns.
  def with_probe_bluebook(registry)
    before = registry.bluebooks.keys
    Hecks.with_registry(registry) { Hecks.bluebook("SyntaxBootMemoProbe", &SYNTAX_BOOT_PROBE_BLUEBOOK) }
    expect(registry.bluebooks.keys - before).to eq(["SyntaxBootMemoProbe"])
    yield
  ensure
    registry.bluebooks.delete("SyntaxBootMemoProbe")
  end

  def warmed_grammar_registry = MetaValidatorUnderTest.grammar_registry.tap { SyntaxBootUnderTest.call }

  # The probe bluebook joins and leaves in one example: its aggregate is declared into the
  # process-wide
  # grammar registry, which a second declaration of the same bluebook would collide with.
  it "boots again the moment a bluebook joins the registry, and again once it leaves" do
    registry = warmed_grammar_registry
    allow(SyntaxBootUnderTest).to receive(:boot).and_call_original
    with_probe_bluebook(registry) { SyntaxBootUnderTest.call }
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

  def distinct_bluebook_sets(registry)
    attached = registry.bluebooks.values.count { |declaration| declaration.attaches_to.any? }
    1 + MetaValidatorUnderTest::LANGUAGE_BLUEBOOKS.size + attached
  end

  # Regression pin: a cold registry build asks for the syntax table once per distinct bluebook set
  # (raw load, one swap per language bluebook, Paging attaching); one boot each suffices.
  it "boots at most once per distinct bluebook set while the grammar registry builds itself from cold", :aggregate_failures do
    counter = boot_counter
    distinct = with_cold_grammar_registry { |registry| distinct_bluebook_sets(registry) }

    expect(counter[:boots]).to be <= distinct
    expect(counter[:boots]).to be < 42
  end
end
