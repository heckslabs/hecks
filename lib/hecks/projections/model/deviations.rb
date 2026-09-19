module Hecks
  module Projections
    module Model
      # How the model's shape differs from the language's, and why.
      #
      # Every construct's `emits_ir` restates what the grammar declares —
      # and the two legitimately differ, in seven ways. These lived only
      # as prose in Ruby comments until spec/model_shape_conformance_spec
      # made them checkable; they live here so the generator and the gate
      # read one source rather than two that must agree.
      #
      # A reason is carried beside each entry because the generated file
      # will carry it: a deviation is exactly the kind of thing whose
      # explanation must survive regeneration, and the only way it can is
      # to be emitted rather than typed into the output.
      module Deviations
        # What the model holds that the grammar declares elsewhere: the
        # containment edges, stated in syntax.bluebook's Keyword rows as
        # `context` -> `opens`.
        CONTAINED = {
          "Bluebook"       => %i[aggregates read_models policies process_managers],
          "Aggregate"      => %i[commands entities queries value_objects],
          # S17, ADR 0026 — an entity may nest further entities now
          # (`Dispatch`, inside `Handler`) — same containment edge as
          # Aggregate's own `entities`, one level down.
          "Entity"         => %i[commands entities queries],
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
          "Aggregate"   => { ports:          "declared in the hecksagon, attached after the aggregate exists" },
          "Policy"      => { where_ast:      "the structured form of `where`, derived from the same text at emission" }
        }.freeze

        # **Declared, and deliberately not emitted**. The category that had no
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

        # The grammar is relational — a Command points up at its
        # Aggregate — where the model composes. An explicit `as:` still
        # keeps its `_id` (Command's own `entity_id`, kept as data); the
        # parent link itself mints bare now (ADR 0025) — `aggregate` or
        # `bluebook`, whichever this category's creating command declares
        # first. Entity spells its own (separate, non-colliding) text twin
        # of the parent link `owner`. Not restated here: the one list is
        # `Assembly::PARENT_POINTERS`, which the assembly gate reads too.
        # Tells whether `field` is a parent pointer, minted bare rather than
        # declared like an ordinary field.
        #
        # @param field [String, Symbol] the field name to check
        # @return [Boolean] true if `field` is a parent pointer (`Assembly::PARENT_POINTERS`,
        #   or any name ending `_id`)
        def parent_ref?(field) = Hecks::Bluebook::Assembly.parent_pointer?(field)

        # The judge's own fields, never the model's — read off the
        # category's contract (`derived: { position: :walk }`), not restated.
        #
        # @param name [String] the construct's name, an `Assembly::CONTRACTS` key
        # @return [Array<Symbol>] fields the assembly judge derives by walking, for this construct
        # @raise [KeyError] if `name` has no assembly contract
        def judge_only(name) = Hecks::Bluebook::Assembly.contract(name).walked

        # The tables that carry a reason answer with names only when the
        # caller wants the set rather than the explanations.
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
