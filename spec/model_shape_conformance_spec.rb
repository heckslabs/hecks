require "spec_helper"

# Holds each construct's `emits_ir` to what bluebook.bluebook declares, allowing five
# named deviations, each categorised and checked.
RSpec.describe "the model's shape, held to the language" do
  MODEL_CONSTRUCTS = {
    "Bluebook"       => Hecks::Bluebook::Chapter,
    "Aggregate"      => Hecks::Bluebook::Aggregate,
    "Command"        => Hecks::Bluebook::Command,
    "Entity"         => Hecks::Bluebook::Entity,
    "ValueObject"    => Hecks::Bluebook::ValueObject,
    "Policy"         => Hecks::Bluebook::Policy,
    "Query"          => Hecks::Bluebook::Query,
    "ReadModel"      => Hecks::Bluebook::ReadModel,
    "ProcessManager" => Hecks::Bluebook::ProcessManager
  }.freeze

  # Named `DEVIATIONS`, not `D`: spec/syntax_conformance_spec claims `D`, and a top-level
  # constant in a spec is shared with every other spec in the run.
  DEVIATIONS = Hecks::Projections::Model::Deviations

  def unaccounted_message(name, unaccounted)
    "#{name} emits #{unaccounted.inspect}, which the language does not declare and " \
      "no category above accounts for — either the language should declare it, or it " \
      "belongs in one of CONTAINED/FOLDED/COMPUTED with a reason"
  end

  MODEL_CONSTRUCTS.each do |name, construct|
    context name do
      let(:language) { Hecks::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook") }
      let(:declared) { language.aggregate(name).attributes.map(&:name) }
      let(:emitted)  { construct.ir_spec.keys }
      let(:accounted) do
        declared.reject { |field| DEVIATIONS.parent_ref?(field) } -
          DEVIATIONS.judge_only(name) -
          DEVIATIONS.folded(name).values.flatten -
          DEVIATIONS.off_the_wire(name) -
          DEVIATIONS.dynamic_tail(name) -
          DEVIATIONS.unpacked(name).keys
      end
      let(:unaccounted) do
        emitted -
          declared -
          DEVIATIONS.contained(name) -
          DEVIATIONS.folded(name).keys -
          DEVIATIONS.computed(name) -
          DEVIATIONS.unpacked(name).values.flatten
      end

      it "emits every declared field that is not accounted for" do
        expect(emitted).to include(*accounted)
      end

      it "emits nothing the language does not declare, bar what is named" do
        expect(unaccounted).to be_empty, unaccounted_message(name, unaccounted)
      end
    end
  end

  # The categories are only worth having if they are all load-bearing.
  it "uses every category it declares", :aggregate_failures do
    [DEVIATIONS::CONTAINED, DEVIATIONS::FOLDED, DEVIATIONS::COMPUTED, DEVIATIONS::OFF_THE_WIRE, DEVIATIONS::DYNAMIC_TAIL,
     DEVIATIONS::UNPACKED].each do |table|
      expect(table).not_to be_empty
      expect(table.keys - MODEL_CONSTRUCTS.keys).to be_empty
    end
  end
end
