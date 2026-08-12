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
  B = Hecksagain::Bluebook

  CONSTRUCTS = {
    "Bluebook"       => B::Chapter,
    "Aggregate"      => B::Aggregate,
    "Command"        => B::Command,
    "Entity"         => B::Entity,
    "ValueObject"    => B::ValueObject,
    "Policy"         => B::Policy,
    "Query"          => B::Query,
    "ReadModel"      => B::ReadModel,
    "ProcessManager" => B::ProcessManager
  }.freeze

  # THE PARENT REFERENCE. The grammar is relational — a Command points UP
  # at its Aggregate — where the model composes: an Aggregate holds its
  # commands. So every `*_id` is the edge the model spells as
  # `hecks_owner`, and no construct emits it.
  # `owner` rather than `*_id` on Entity — the same edge, spelled
  # differently by the one construct that can be declared inside another
  # entity as well as inside an aggregate.
  PARENT_REF = ->(field) { field.to_s.match?(/_id\z/) || field == :owner }

  # THE JUDGE'S OWN FIELD, never the model's — contracts.rb already says
  # so with `derived: { position: :walk }`.
  JUDGE_ONLY = %i[position].freeze

  # WHAT THE MODEL HOLDS THAT THE GRAMMAR DECLARES ELSEWHERE. These are
  # the containment edges, and they are declared — in syntax.bluebook's
  # Keyword rows, as `context` -> `opens`. spec/assembly_spec's own note
  # that containment "cannot be derived from the plan" is true of the
  # PLAN and not of the language.
  CONTAINED = {
    "Bluebook"       => %i[aggregates read_models policies process_managers],
    "Aggregate"      => %i[commands entities queries value_objects],
    "Entity"         => %i[commands queries],
    "ValueObject"    => %i[members],
    "ProcessManager" => %i[handlers]
  }.freeze

  # ONE MODEL FIELD GATHERED FROM SEVERAL DECLARED ONES — contracts.rb's
  # own `[:folded, :lifecycle, :field]` shape, stated here as the pair it
  # actually is.
  FOLDED = {
    "Aggregate" => { lifecycle: %i[state_field state_start transitions] },
    # An entity carries a lifecycle exactly as an aggregate does, and the
    # language flattens it exactly the same way.
    "Entity"    => { lifecycle: %i[state_field state_start transitions] },
    "Query"     => { order_by: %i[order_field order_way] }
  }.freeze

  # MODEL-ONLY, and each for its own reason rather than by oversight.
  COMPUTED = {
    # The EMISSION's version, not the domain's — see Chapter::IR_VERSION.
    "Bluebook"    => %i[ir_version canonical_form],
    # A one_of declared but left empty is indistinguishable from no
    # one_of at all unless the flag is carried.
    "ValueObject" => %i[closed_set],
    # Ports are declared in the HECKSAGON, not the bluebook, and attach
    # after the aggregate exists — `Behaviour::Aggregate#add_port`.
    "Aggregate"   => %i[ports]
  }.freeze

  # DECLARED, AND DELIBERATELY NOT ON THE WIRE. The category that had no
  # home: each of these is a real field the language declares and the
  # model deliberately does not emit, recorded until now only in a
  # comment.
  OFF_THE_WIRE = {
    # "the wire format is a pinned contract, and it does not carry this"
    # — Policy#aggregate, which records WHERE a policy was written after
    # the builder hoists it onto the chapter.
    "Policy"      => %i[aggregate],
    # A rename's old name and the normalisation table are facts about
    # the source that the export has never carried.
    "Bluebook"    => %i[formerly_known_as normalisations],
    # `rows` is the language's name for a closed set's members; the model
    # emits them under `members`.
    "ValueObject" => %i[rows]
  }.freeze

  # THE INVERSE OF A FOLD: one declared field opening into several the
  # model holds apart. A read model's `options` carries the whole query
  # specification, which the model splits into the three fields every
  # reader of it actually asks for.
  UNPACKED = {
    "ReadModel" => { options: %i[wheres order_by limit] }
  }.freeze

  # EMITTED BY `to_h`'s OWN MERGE rather than by `emits_ir` — the two
  # constructs whose shape is genuinely not fixed, because the query
  # specification layer grew options after them.
  DYNAMIC_TAIL = {
    "Query"     => %i[options],
    "ReadModel" => %i[options group_by aggregate_heads]
  }.freeze

  CONSTRUCTS.each do |name, construct|
    context name do
      let(:language) { Hecksagain::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook") }
      let(:declared) { language.aggregate(name).attributes.map(&:name) }
      let(:emitted)  { construct.ir_spec.keys }

      it "emits every declared field that is not accounted for" do
        accounted = declared.reject { |field| PARENT_REF.call(field) } -
                    JUDGE_ONLY -
                    FOLDED.fetch(name, {}).values.flatten -
                    OFF_THE_WIRE.fetch(name, []) -
                    DYNAMIC_TAIL.fetch(name, []) -
                    UNPACKED.fetch(name, {}).keys

        expect(emitted).to include(*accounted)
      end

      it "emits nothing the language does not declare, bar what is named" do
        unaccounted = emitted -
                      declared -
                      CONTAINED.fetch(name, []) -
                      FOLDED.fetch(name, {}).keys -
                      COMPUTED.fetch(name, []) -
                      UNPACKED.fetch(name, {}).values.flatten

        expect(unaccounted).to be_empty,
          "#{name} emits #{unaccounted.inspect}, which the language does not declare and " \
          "no category above accounts for — either the language should declare it, or it " \
          "belongs in one of CONTAINED/FOLDED/COMPUTED with a reason"
      end
    end
  end

  # The categories are only worth having if they are ALL load-bearing.
  it "uses every category it declares" do
    [CONTAINED, FOLDED, COMPUTED, OFF_THE_WIRE, DYNAMIC_TAIL, UNPACKED].each do |table|
      expect(table).not_to be_empty
      expect(table.keys - CONSTRUCTS.keys).to be_empty
    end
  end
end
