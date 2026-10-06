require "spec_helper"

RSpec.describe Hecks::Bluebook::MetaValidator::TranslationJudge do
  let(:meta_language) do
    Hecks::Bluebook::MetaValidator.grammar_registry.bluebook("Translation")
  end

  let(:translation_aggregate) { meta_language.aggregate("TranslationAggregate") }

  def command_references = translation_aggregate.commands.map { |command| [command.name, command.references] }

  it "retains the translation parent as a relationship without behavioral self references", :aggregate_failures do
    attribute = translation_aggregate.attribute(:translation_ref)

    expect([attribute.type.to_s, attribute.relationship]).to eq(["Reference<Translation>", "belongs_to"])
    expect(translation_aggregate.command("Declare").attribute(:translation_ref).type.to_s).to eq("TranslationIdentity")
    expect(command_references).to all(satisfy { |_, ref| ref.nil? })
    expect(meta_language.aggregate("Translation").command("Retire").references).to be_nil
  end

  # One TranslationJudge construction records all dispatched calls into
  # one shared `calls` array, then checks both the exact set of routed
  # mutations and that no call leaks an :id/:aggregate key across any of
  # them — splitting would mean re-running the judge per mutation kind
  # for no real gain, and would lose the "none of them leak" claim.
  describe "the calls a judged translation dispatches" do
    let(:calls) { [] }

    # Records every dispatch into `calls` instead of running it.
    def record_dispatches
      recorded = calls
      runtime = Object.new
      runtime.define_singleton_method(:dispatch) do |verb, to:, with:|
        recorded << { verb: verb, to: to, with: with }
      end
      allow(Hecks::Bluebook::MetaValidator).to receive(:fresh_runtime).and_return(runtime)
    end

    def banking_translation
      aggregate = Hecks::Bluebook::TranslationAggregate.new(
        name:      "Account",
        renames:   { old_name: :new_name },
        backfills: [Hecks::Bluebook::TranslationBackfill.new(:tier, "standard")]
      )
      Hecks::Bluebook::Translation.new(
        domain: "Banking", from: "held", to: "current",
        aggregates: [aggregate], retired: ["Ledger"]
      )
    end

    def declare_call
      { verb: "Translation::TranslationAggregate.Declare", to: nil,
        with: { translation_ref: { domain: { value: "Banking" }, from: { value: "held" }, to: { value: "current" } },
                name:            { value: "Account" } } }
    end

    def retire_call
      { verb: "Translation::Translation.Retire", to: Hecks::Naming.identity(%w[Banking held current]),
        with: { value: { value: "Ledger" } } }
    end

    def rename_call
      { verb: "Translation::TranslationAggregate.AddRename", to: "Account",
        with: { from: { value: "old_name" }, to: { value: "new_name" } } }
    end

    def backfill_call
      { verb: "Translation::TranslationAggregate.AddBackfill", to: "Account",
        with: { name: { value: "tier" }, default: { value: "\"standard\"" } } }
    end

    it "routes mutations separately from their declared facts, including AddBackfill", :aggregate_failures do
      record_dispatches
      described_class.new(banking_translation)

      expect(calls).to include(retire_call, declare_call, rename_call, backfill_call)
      expect(calls.flat_map { |call| call[:with].keys }).not_to include(:id, :aggregate)
    end
  end
end
