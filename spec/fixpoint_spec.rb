require "spec_helper"
require "tmpdir"

# The language passes its own rules and runs from its own records.
# The bootstrap loads it raw (judging while loading would recurse); `grammar_registry` judges it.
RSpec.describe "the language's own definition" do
  def meta = Hecks::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")

  it "is judged by the rules it declares, and passes" do
    refusals = Hecks::Bluebook::MetaValidator::Judge.new(meta).refusals

    expect(refusals).to be_empty
  end

  def language_shapes
    ["Bluebook", "Aggregate", "Command", "ValueObject", "Query", "Entity",
     "Policy", "ProcessManager", "ReadModel", "Vocabulary"]
  end

  it "declares the shapes a bluebook is made of", :aggregate_failures do
    # A category the language stops describing goes unjudged silently: the judge skips it.
    expect(meta.aggregates.map(&:name)).to include(*language_shapes)

    # Member is an entity nested under ValueObject (ADR 0026), so it is found via `.entities`.
    value_object = meta.aggregates.find { |aggregate| aggregate.hecks_name == "ValueObject" }
    expect(value_object.entities.map(&:hecks_name)).to include("Member")
  end

  FIXPOINT_SILENT_BLUEBOOK = <<~BLUEBOOK.freeze
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

  def boot_silent_bluebook
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "silent.bluebook"), FIXPOINT_SILENT_BLUEBOOK)
      Hecks.boot(dir)
    end
  end

  it "is what actually refuses a malformed bluebook, end to end" do
    # Goes through the real load path, not the judge: `emits ""` is refused only
    # because the language says so, since no builder raises for it.
    expect { boot_silent_bluebook }.to raise_error(Hecks::Bluebook::DSL::Malformed, /an event is named/)
  end

  # Rebinds a fresh grammar registry and yields it, then restores the memoized one.
  def with_fresh_grammar_registry
    validator = Hecks::Bluebook::MetaValidator
    original = %i[@grammar_registry @grammar_ready_for].to_h { |name| [name, validator.instance_variable_get(name)] }
    validator.instance_variable_set(:@grammar_registry, nil)
    registry = validator.grammar_registry
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    yield registry
  ensure
    original.each { |name, value| validator.instance_variable_set(name, value) }
  end

  # Resets the singleton and binds fresh: any spec that binds another runtime repoints the
  # global constants, so registry/door agreement only holds right after a bind.
  # The memoized registry is restored afterward so ir_golden_spec.rb's byte-for-byte
  # comparison still sees the first-boot registry regardless of process order.
  it "runs from its own records — registry and the installed door agree from bind", :aggregate_failures do
    with_fresh_grammar_registry do |registry|
      expect(Object.const_get(:Bluebook).const_get(:Aggregate).ir).to be(registry.bluebook("Bluebook").aggregate("Aggregate"))
      expect(Object.const_get(:World).const_get(:World).ir).to be(registry.bluebook("World").aggregate("World"))
    end
  end

  # `:members` values are stringified on both sides: the raw load keeps declared types,
  # while `Assembly::Marks#member` guesses types (`unmark_scalar`), which
  # spec/vocabulary_conformance_spec.rb relies on. Everything else compares byte for byte.
  def stringify_members(node)
    case node
    when Hash
      node.to_h { |key, value| [key, key == :members ? stringify_member_rows(value) : stringify_members(value)] }
    when Array
      node.map { |item| stringify_members(item) }
    else
      node
    end
  end

  def stringify_member_rows(rows)
    Array(rows).map { |row| row.map { |field, value| [field, value.to_s] } }
  end

  it "lost nothing on the way through — assembled equals a fresh raw load, chapter for chapter" do
    registry = Hecks::Bluebook::MetaValidator.grammar_registry
    raw = Hecks::Bluebook::MetaValidator.load_grammar_into(Hecks::Runtime::Registry.new)

    Hecks::Bluebook::MetaValidator::LANGUAGE_CHAPTERS.each do |name|
      expect(stringify_members(registry.bluebook(name).to_h)).to eq(stringify_members(raw.bluebook(name).to_h))
    end
  end
end
