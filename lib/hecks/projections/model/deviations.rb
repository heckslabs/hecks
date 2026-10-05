module Hecks
  module Projections
    module Model
      # How the model's shape legitimately differs from the language's, and why.
      # The generator and spec/model_shape_conformance_spec read these tables.
      module Deviations
        # Fields the model holds that the grammar declares as containment edges
        # (syntax.bluebook's Keyword rows, `context` -> `opens`).
        CONTAINED = {
          "Bluebook"       => %i[aggregates read_models policies process_managers],
          "Aggregate"      => %i[commands entities queries value_objects],
          # An entity may nest further entities (`Dispatch` inside `Handler`) (ADR 0026).
          "Entity"         => %i[commands entities queries],
          "ValueObject"    => %i[members],
          "ProcessManager" => %i[handlers]
        }.freeze

        # One model field gathered from several declared ones.
        FOLDED = {
          "Aggregate" => { lifecycle: %i[state_field state_start transitions] },
          "Entity"    => { lifecycle: %i[state_field state_start transitions] },
          "Query"     => { order_by: %i[order_field order_way] }
        }.freeze

        # The inverse of a fold: one declared field opening into several model fields.
        UNPACKED = {
          "ReadModel" => { options: %i[wheres order_by limit] }
        }.freeze

        # Model-only fields, each with its reason.
        COMPUTED = {
          "Bluebook"    => { ir_version:     "the EMISSION's own version, not the domain's",
                             canonical_form: "the normalisation table every reader needs beside the IR" },
          "ValueObject" => { closed_set:     "an empty one_of and no one_of are otherwise indistinguishable" },
          "Aggregate"   => { ports:          "declared in the hecksagon, attached after the aggregate exists" },
          "Policy"      => { where_ast:      "the structured form of `where`, derived from the same text at emission" }
        }.freeze

        # Declared but deliberately not emitted, each with its reason.
        OFF_THE_WIRE = {
          "Policy"      => { aggregate: "the wire format is a pinned contract, and it does not carry " \
                                        "where a policy was written before the builder hoisted it" },
          "Bluebook"    => { formerly_known_as: "a rename's old name is a fact about the source",
                             normalisations:    "the normalisation table rides on canonical_form instead" },
          "ValueObject" => { rows: "the language's name for a closed set's members; emitted as `members`" }
        }.freeze

        # Fields emitted by `to_h`'s own merge rather than `emits_ir`, for constructs
        # whose shape is not fixed.
        DYNAMIC_TAIL = {
          "Query"     => %i[options returns needs],
          "ReadModel" => %i[options group_by aggregate_heads count median_field sum_field avg_field
                            min_field max_field percentile_field percentile_at any_field all_field]
        }.freeze

        module_function

        # Tells whether `field` is a parent pointer, minted bare rather than
        # declared like an ordinary field.
        #
        # @param field [String, Symbol] the field name to check
        # @return [Boolean] true if `field` is a parent pointer (`Assembly::PARENT_POINTERS`,
        #   or any name ending `_id`)
        def parent_ref?(field) = Hecks::Bluebook::Assembly.parent_pointer?(field)

        # The judge's own fields, read off the category's contract (`derived: {...: :walk}`).
        #
        # @param name [String] the construct's name, an `Assembly::CONTRACTS` key
        # @return [Array<Symbol>] fields the assembly judge derives by walking, for this construct
        # @raise [KeyError] if `name` has no assembly contract
        def judge_only(name) = Hecks::Bluebook::Assembly.contract(name).walked

        # The names in `OFF_THE_WIRE`, without the reasons.
        #
        # @param name [String] the construct's name, an `OFF_THE_WIRE` key
        # @return [Array<Symbol>] fields declared but deliberately not emitted for `name`;
        #   empty if `name` has none
        def off_the_wire(name) = OFF_THE_WIRE.fetch(name, {}).keys

        # Names `name`'s model-only fields.
        #
        # @param name [String] the construct's name, a `COMPUTED` key
        # @return [Array<Symbol>] model-only fields computed rather than declared for
        #   `name`; empty if `name` has none
        def computed(name)     = COMPUTED.fetch(name, {}).keys

        # Names `name`'s containment edges.
        #
        # @param name [String] the construct's name, a `CONTAINED` key
        # @return [Array<Symbol>] fields the model holds that the grammar declares as
        #   containment edges instead, for `name`; empty if `name` has none
        def contained(name)    = CONTAINED.fetch(name, [])

        # Names `name`'s folded fields and what each gathers.
        #
        # @param name [String] the construct's name, a `FOLDED` key
        # @return [Hash{Symbol => Array<Symbol>}] each folded field for `name`, mapped to
        #   the declared fields it gathers; empty if `name` has none
        def folded(name)       = FOLDED.fetch(name, {})

        # Names `name`'s unpacked fields and what each opens into.
        #
        # @param name [String] the construct's name, an `UNPACKED` key
        # @return [Hash{Symbol => Array<Symbol>}] each declared field for `name` that opens
        #   into several model fields, mapped to those fields; empty if `name` has none
        def unpacked(name)     = UNPACKED.fetch(name, {})

        # Names `name`'s dynamic-tail fields.
        #
        # @param name [String] the construct's name, a `DYNAMIC_TAIL` key
        # @return [Array<Symbol>] fields for `name` emitted by `to_h`'s own merge rather
        #   than by `emits_ir`; empty if `name` has none
        def dynamic_tail(name) = DYNAMIC_TAIL.fetch(name, [])
      end
    end
  end
end
