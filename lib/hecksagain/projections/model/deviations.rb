module Hecksagain
  module Projections
    module Model
      # HOW THE MODEL'S SHAPE DIFFERS FROM THE LANGUAGE'S, and why.
      #
      # Every construct's `emits_ir` restates what the grammar declares —
      # and the two legitimately differ, in seven ways. These lived only
      # as prose in Ruby comments until spec/model_shape_conformance_spec
      # made them checkable; they live HERE so the generator and the gate
      # read one source rather than two that must agree.
      #
      # A reason is carried beside each entry because the generated file
      # will CARRY it: a deviation is exactly the kind of thing whose
      # explanation must survive regeneration, and the only way it can is
      # to be emitted rather than typed into the output.
      module Deviations
        # The grammar is relational — a Command points UP at its
        # Aggregate — where the model composes. An explicit `as:` still
        # keeps its `_id` (Command's own `entity_id`, kept as data); the
        # parent link itself mints bare now (ADR 0025) — `aggregate` or
        # `bluebook`, whichever this category's creating command declares
        # first — so both spellings are checked. Entity spells its own
        # (separate, non-colliding) text twin of the parent link `owner`.
        PARENT_REF = ->(field) { field.to_s.match?(/_id\z/) || %i[owner aggregate bluebook].include?(field) }

        # The judge's own field, never the model's — contracts.rb already
        # says so with `derived: { position: :walk }`.
        JUDGE_ONLY = %i[position].freeze

        # What the model holds that the grammar declares elsewhere: the
        # containment edges, stated in syntax.bluebook's Keyword rows as
        # `context` -> `opens`.
        CONTAINED = {
          "Bluebook"       => %i[aggregates read_models policies process_managers],
          "Aggregate"      => %i[commands entities queries value_objects],
          "Entity"         => %i[commands queries],
          "ValueObject"    => %i[members],
          "ProcessManager" => %i[handlers]
        }.freeze

        # One model field gathered from several declared ones —
        # contracts.rb's own `[:folded, ...]` shape, as the pair it is.
        FOLDED = {
          "Aggregate" => { lifecycle: %i[state_field state_start transitions] },
          "Entity"    => { lifecycle: %i[state_field state_start transitions] },
          "Query"     => { order_by: %i[order_field order_way] }
        }.freeze

        # The inverse of a fold, and it had no name at all: one declared
        # field opening into several the model holds apart.
        UNPACKED = {
          "ReadModel" => { options: %i[wheres order_by limit] }
        }.freeze

        # Model-only, each for its own reason rather than by oversight.
        COMPUTED = {
          "Bluebook"    => { ir_version:     "the EMISSION's own version, not the domain's",
                             canonical_form: "the normalisation table every reader needs beside the IR" },
          "ValueObject" => { closed_set:     "an empty one_of and no one_of are otherwise indistinguishable" },
          "Aggregate"   => { ports:          "declared in the hecksagon, attached after the aggregate exists" }
        }.freeze

        # DECLARED, AND DELIBERATELY NOT EMITTED. The category that had no
        # home anywhere before — each of these was a comment and nothing
        # more.
        OFF_THE_WIRE = {
          "Policy"      => { aggregate: "the wire format is a pinned contract, and it does not carry " \
                                        "where a policy was written before the builder hoisted it" },
          "Bluebook"    => { formerly_known_as: "a rename's old name is a fact about the source",
                             normalisations:    "the normalisation table rides on canonical_form instead" },
          "ValueObject" => { rows: "the language's name for a closed set's members; emitted as `members`" }
        }.freeze

        # Emitted by `to_h`'s own merge rather than by `emits_ir` — the
        # two constructs whose shape is genuinely not fixed, because the
        # query specification layer grew options after them.
        DYNAMIC_TAIL = {
          "Query"     => %i[options],
          "ReadModel" => %i[options group_by aggregate_heads count median_field]
        }.freeze

        module_function

        # The tables that carry a reason answer with names only when the
        # caller wants the set rather than the explanations.
        def off_the_wire(name) = OFF_THE_WIRE.fetch(name, {}).keys
        def computed(name)     = COMPUTED.fetch(name, {}).keys
        def contained(name)    = CONTAINED.fetch(name, [])
        def folded(name)       = FOLDED.fetch(name, {})
        def unpacked(name)     = UNPACKED.fetch(name, {})
        def dynamic_tail(name) = DYNAMIC_TAIL.fetch(name, [])
      end
    end
  end
end
