require "spec_helper"

# THE MODEL'S SHAPE, HELD TO THE LANGUAGE THAT DECLARES IT.
#
# Every construct's `emits_ir` restates what `bluebook.bluebook` already
# says — and the two are allowed to differ, in five specific ways that
# until now lived only as prose in Ruby comments. A generator cannot be
# written against prose, so this is those decisions as data: each
# deviation named, categorised, and checked.
#
# The categories are not invented here. Four of the five already exist
# somewhere: the parent reference is `Construct`'s owner chain, `position`
# is `contracts.rb`'s own `derived: :walk`, the folds are its
# `[:folded, ...]` entries, and containment is `syntax.bluebook`'s
# `context`/`opens` columns. Only "declared but deliberately off the
# wire" had no home at all.
RSpec.describe "the model's shape, held to the language" do
  MODEL_CONSTRUCTS = {
    "Bluebook"       => Hecksagain::Bluebook::Chapter,
    "Aggregate"      => Hecksagain::Bluebook::Aggregate,
    "Command"        => Hecksagain::Bluebook::Command,
    "Entity"         => Hecksagain::Bluebook::Entity,
    "ValueObject"    => Hecksagain::Bluebook::ValueObject,
    "Policy"         => Hecksagain::Bluebook::Policy,
    "Query"          => Hecksagain::Bluebook::Query,
    "ReadModel"      => Hecksagain::Bluebook::ReadModel,
    "ProcessManager" => Hecksagain::Bluebook::ProcessManager
  }.freeze

  # THE DEVIATION TABLES LIVE IN lib, not here. They began as this
  # spec's own constants, which made the gate the only thing that knew
  # them — and a generator cannot read a spec. Moved to
  # Projections::Model::Deviations so the gate and the generator read one
  # source instead of two that have to agree.
  # Named for this spec, not `D` — spec/syntax_conformance_spec already
  # claims that for Bluebook::DSL, and a top-level constant in a spec is
  # shared with every other spec in the run. Passing alone and failing in
  # the suite is exactly what that looks like.
  DEVIATIONS = Hecksagain::Projections::Model::Deviations

  MODEL_CONSTRUCTS.each do |name, construct|
    context name do
      let(:language) { Hecksagain::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook") }
      let(:declared) { language.aggregate(name).attributes.map(&:name) }
      let(:emitted)  { construct.ir_spec.keys }

      it "emits every declared field that is not accounted for" do
        accounted = declared.reject { |field| DEVIATIONS::PARENT_REF.call(field) } -
                    DEVIATIONS::JUDGE_ONLY -
                    DEVIATIONS.folded(name).values.flatten -
                    DEVIATIONS.off_the_wire(name) -
                    DEVIATIONS.dynamic_tail(name) -
                    DEVIATIONS.unpacked(name).keys

        expect(emitted).to include(*accounted)
      end

      it "emits nothing the language does not declare, bar what is named" do
        unaccounted = emitted -
                      declared -
                      DEVIATIONS.contained(name) -
                      DEVIATIONS.folded(name).keys -
                      DEVIATIONS.computed(name) -
                      DEVIATIONS.unpacked(name).values.flatten

        expect(unaccounted).to be_empty,
                               "#{name} emits #{unaccounted.inspect}, which the language does not declare and " \
                               "no category above accounts for — either the language should declare it, or it " \
                               "belongs in one of CONTAINED/FOLDED/COMPUTED with a reason"
      end
    end
  end

  # The categories are only worth having if they are ALL load-bearing.
  it "uses every category it declares" do
    [DEVIATIONS::CONTAINED, DEVIATIONS::FOLDED, DEVIATIONS::COMPUTED, DEVIATIONS::OFF_THE_WIRE, DEVIATIONS::DYNAMIC_TAIL,
     DEVIATIONS::UNPACKED].each do |table|
      expect(table).not_to be_empty
      expect(table.keys - MODEL_CONSTRUCTS.keys).to be_empty
    end
  end
end
