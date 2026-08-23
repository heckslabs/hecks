require "spec_helper"

RSpec.describe Hecksagain::Bluebook::MetaValidator::TranslationJudge do
  let(:meta_language) do
    Hecksagain::Bluebook::MetaValidator.grammar_registry.bluebook("Translation")
  end

  it "retains the translation parent as a relationship without behavioral self references" do
    aggregate = meta_language.aggregate("TranslationAggregate")

    expect(aggregate.attribute(:translation_ref).then { |attribute|
      [attribute.type.to_s, attribute.relationship]
    }).to eq(["Reference<Translation>", "belongs_to"])
    expect(aggregate.command("Declare").attribute(:translation_ref).type.to_s).to eq("TranslationIdentity")
    expect(aggregate.commands.map { |command| [command.name, command.references] }).to all(satisfy { |_, ref|
      ref.nil?
    })
    expect(meta_language.aggregate("Translation").command("Retire").references).to be_nil
  end

  it "routes mutations separately from their declared facts, including AddBackfill" do
    calls = []
    runtime = Object.new
    runtime.define_singleton_method(:dispatch) do |verb, to:, with:|
      calls << { verb: verb, to: to, with: with }
    end
    allow(Hecksagain::Bluebook::MetaValidator).to receive(:fresh_runtime).and_return(runtime)

    aggregate = Hecksagain::Bluebook::TranslationAggregate.new(
      name:      "Account",
      renames:   { old_name: :new_name },
      backfills: [Hecksagain::Bluebook::TranslationBackfill.new(:tier, "standard")]
    )
    translation = Hecksagain::Bluebook::Translation.new(
      domain: "Banking", from: "held", to: "current",
      aggregates: [aggregate], retired: ["Ledger"]
    )

    described_class.new(translation)

    translation_id = Hecksagain::Naming.identity(%w[Banking held current])
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
