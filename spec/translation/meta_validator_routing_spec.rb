require "spec_helper"

RSpec.describe Hecks::Bluebook::MetaValidator::TranslationJudge do
  let(:meta_language) do
    Hecks::Bluebook::MetaValidator.grammar_registry.bluebook("Translation")
  end

  it "retains the translation parent as a relationship without behavioral self references" do
    aggregate = meta_language.aggregate("TranslationAggregate")

    expect(aggregate.attribute(:translation_ref).then do |attribute|
      [attribute.type.to_s, attribute.relationship]
    end).to eq(["Reference<Translation>", "belongs_to"])
    expect(aggregate.command("Declare").attribute(:translation_ref).type.to_s).to eq("TranslationIdentity")
    expect(aggregate.commands.map { |command| [command.name, command.references] }).to all(satisfy { |_, ref|
      ref.nil?
    })
    expect(meta_language.aggregate("Translation").command("Retire").references).to be_nil
  end

  # One TranslationJudge construction records ALL dispatched calls into
  # one shared `calls` array, then checks both the exact set of routed
  # mutations AND that no call leaks an :id/:aggregate key across any of
  # them — splitting would mean re-running the judge per mutation kind
  # for no real gain, and would lose the "none of them leak" claim.
  # rubocop:disable-next RSpec/ExampleLength
  it "routes mutations separately from their declared facts, including AddBackfill" do
    calls = []
    runtime = Object.new
    runtime.define_singleton_method(:dispatch) do |verb, to:, with:|
      calls << { verb: verb, to: to, with: with }
    end
    allow(Hecks::Bluebook::MetaValidator).to receive(:fresh_runtime).and_return(runtime)

    aggregate = Hecks::Bluebook::TranslationAggregate.new(
      name:      "Account",
      renames:   { old_name: :new_name },
      backfills: [Hecks::Bluebook::TranslationBackfill.new(:tier, "standard")]
    )
    translation = Hecks::Bluebook::Translation.new(
      domain: "Banking", from: "held", to: "current",
      aggregates: [aggregate], retired: ["Ledger"]
    )

    described_class.new(translation)

    translation_id = Hecks::Naming.identity(%w[Banking held current])
    expect(calls).to include(
      {
        verb: "Translation::Translation.Retire",
        to:   translation_id,
        with: { value: { value: "Ledger" } }
      },
      {
        verb: "Translation::TranslationAggregate.Declare",
        to:   nil,
        with: {
          translation_ref: {
            domain: { value: "Banking" },
            from:   { value: "held" },
            to:     { value: "current" }
          },
          name:            { value: "Account" }
        }
      },
      {
        verb: "Translation::TranslationAggregate.AddRename",
        to:   "Account",
        with: { from: { value: "old_name" }, to: { value: "new_name" } }
      },
      {
        verb: "Translation::TranslationAggregate.AddBackfill",
        to:   "Account",
        with: { name: { value: "tier" }, default: { value: "\"standard\"" } }
      }
    )
    expect(calls.flat_map { |call| call[:with].keys }).not_to include(:id, :aggregate)
  end
end
