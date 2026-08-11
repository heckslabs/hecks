module RustProjection
  module Projector
    module_function

    # ── NAMED QUERY CODEGEN — the subset of a declared `query "X" do
    # ... end` block expressible as one or more field-comparator
    # conditions, ANDed together, against a single aggregate's OWN
    # attributes: exactly `kernel/repository.rs`'s existing `filter_
    # entries`/`AggregateScan` machinery, called once per where clause
    # with THIS query's own declared conditions baked in instead of
    # supplied ad hoc over the wire. `query_skip_reason` is the single
    # gate every other function here answers to; `query_conditions` only
    # ever runs once a query has already passed it.
    #
    # WHAT THIS DELIBERATELY DOES NOT COVER, and why — read together with
    # `query_where_skip_reason` below:
    #
    #   order_by / limit / offset / cursor / consistency / freshness /
    #   authorization / null_semantics / inspection / use_index — every
    #   one of these is a real capability `Ports::Query::Ordering`/
    #   `Runtime::QueryInterpreter` implements and this generator does
    #   not attempt to port. Sorting in particular needs a SECOND kernel
    #   capability (a declared-field comparator sort, tie-broken by id)
    #   this branch's minimal query engine never built — baking a where-
    #   only answer for a query that DECLARES an order would be exactly
    #   the silently-wrong shape this whole project refuses to ship.
    #
    #   a where clause hopping through a reference (`customer.status`) —
    #   cross-aggregate joins are `read_model` territory, a different,
    #   still-wholly-ungenerated IR construct (domain_generator.rb's own
    #   header). Detected here as a side effect of `query_field_kind`
    #   simply failing to resolve the field's head against this
    #   aggregate's own declared attributes/lifecycle field: a hop's own
    #   head names an ACCESSOR alias (`Naming.reference_hop`), never the
    #   attribute's real storage name, so it never matches.
    #
    #   a LITERAL (non-Symbol) where value whose true JSON type this
    #   generator cannot recover. `QuerySpecification::Common::
    #   WhereClause#to_h` — the only shape `bin/ir`'s exported IR (what
    #   this generator actually reads) ever carries a where clause's own
    #   value AS — renders EVERY literal through `QuerySpecification.
    #   render_value`, which is `value.to_s` for anything that isn't a
    #   Symbol: an Integer literal `1000` and a String literal `"1000"`
    #   are already indistinguishable by the time this file ever sees
    #   them. `gt`/`gte`/`lt`/`lte` need real Json::Num-vs-Json::Str
    #   fidelity to mean anything at all (query_comparators.rs's own
    #   `ordered?` gate), so a literal comparator value is never eligible
    #   there. `eq`/`ne` only need that fidelity when the TARGET field
    #   itself could ever reduce to something other than a string
    #   (`Ports::Query::InMemory#comparable`'s own numeric-member-wins,
    #   else-single-member-collapses rule) — `query_field_kind` walks the
    #   SAME declared-shape collapse, so a literal `eq`/`ne` is only
    #   generated when it lands on a field that's provably string-shaped.
    #   `in`/`contains` are the one pair of comparators exempt from this
    #   entirely: both stringify their OWN argument unconditionally in
    #   Ruby (`Ports::Query::InMemory#members`/`#contains?`, read
    #   directly — `value.to_s.split(",")`/`want.to_s`, neither gated on
    #   the value's real type), so a rendered-string literal is exactly
    #   as correct there as whatever the original value really was.
    #
    # A Symbol-valued where (`where(actor_id: :actor_id)`) is exempt from
    # all of the literal-safety reasoning above: it resolves against
    # THIS call's own wire `args` at dispatch time (kernel/named_query.rs),
    # which carries its real JSON type already — no IR round trip to lose
    # it through.

    COMPARATORS_NEEDING_NUMERIC_FIDELITY = %w[gt gte lt lte].freeze
    COMPARATORS_EXEMPT_FROM_LITERAL_TYPING = %w[in contains].freeze

    # The declared attribute (or synthetic lifecycle field) `field`'s
    # HEAD segment names on `aggregate`, walked through nested value
    # objects for any segments after it — `:unknown` for anything that
    # ISN'T one of this aggregate's own attributes (a hop's own accessor
    # alias never matches a real attribute name, so this doubles as the
    # hop/cross-aggregate detector this file's own header describes).
    #
    #   :string  — this field's `comparable`-reduced value is ALWAYS a
    #              JSON string (a plain `String`/lifecycle field, a bare
    #              `Reference<X>` id, or a value object that collapses —
    #              no numeric member, exactly one member — to one).
    #   :number  — collapses to a JSON number (a numeric primitive, or a
    #              value object carrying a numeric member — the member
    #              that wins `comparable`'s own numeric-first rule).
    #   :other   — resolves, but to something a literal can never safely
    #              represent (a `list_of` attribute read as a bare
    #              scalar, a multi-member non-numeric value object that
    #              stays a whole JSON object).
    #   :unknown — does not resolve against this aggregate's own declared
    #              shape at all.
    def query_field_kind(aggregate, field, value_objects_by_name)
      segments = field.to_s.split(".")
      head = segments.first
      rest = segments[1..] || []

      lifecycle_field = aggregate[:lifecycle] && aggregate[:lifecycle][:field]
      return rest.empty? ? :string : :unknown if lifecycle_field && lifecycle_field.to_s == head

      attr = aggregate[:attributes].find { |a| a[:name].to_s == head }
      return :unknown unless attr
      # A `list_of` field's own comparable value is the array itself
      # (or, under `contains`, each element's OWN reduction) — never a
      # bare scalar a literal `eq`/`ne` could safely target. `contains`/
      # `in` never consult this at all (see `query_where_skip_reason`),
      # so this only ever disqualifies the pair it should.
      return :other if attr[:list]

      query_type_kind(attr[:type].to_s, rest, value_objects_by_name)
    end

    def query_type_kind(type_name, segments, value_objects_by_name)
      return :unknown if reference_type?(type_name) && !segments.empty?
      return :string if reference_type?(type_name)

      if segments.empty?
        query_scalar_or_vo_kind(type_name, value_objects_by_name)
      else
        vo = value_objects_by_name[type_name]
        return :unknown unless vo

        member = vo[:attributes].find { |a| a[:name].to_s == segments.first }
        return :unknown if member.nil? || member[:list]

        query_type_kind(member[:type].to_s, segments[1..] || [], value_objects_by_name)
      end
    end

    def query_scalar_or_vo_kind(type_name, value_objects_by_name)
      case type_name
      when "String" then :string
      when "Integer", "Float" then :number
      when "TrueClass", "FalseClass" then :other
      else
        vo = value_objects_by_name[type_name]
        vo ? query_vo_collapse_kind(vo, value_objects_by_name) : :unknown
      end
    end

    # `Ports::Query::InMemory#comparable`'s own declared-shape mirror: a
    # numeric member wins outright; a genuinely single-member value
    # object collapses to that one member's own kind; anything else (0
    # or 2+ non-numeric members) stays a whole JSON object, which a
    # literal query value can never safely represent.
    def query_vo_collapse_kind(vo, value_objects_by_name)
      return :number if vo[:attributes].any? { |a| %w[Integer Float].include?(a[:type].to_s) }
      return query_type_kind(vo[:attributes].first[:type].to_s, [], value_objects_by_name) if vo[:attributes].size == 1

      :other
    end

    # One where clause's own eligibility — `nil` (clean) or a specific,
    # honest reason string. See this file's own header for the full
    # argument; this is just that argument turned into a gate.
    def query_where_skip_reason(where, aggregate, value_objects_by_name)
      field = where[:field].to_s
      kind = query_field_kind(aggregate, field, value_objects_by_name)
      if kind == :unknown
        return "where clause on #{field.inspect} isn't a recognized attribute of this aggregate — a hop through a " \
               "reference, an entity-scoped field, or simply undeclared here; cross-aggregate joins are read_model " \
               "territory, not this generator's job"
      end

      raw_value = where[:value].to_s
      return nil if raw_value.start_with?(":") # Symbol-valued — resolved from real, correctly-typed wire args at dispatch time

      op = where[:op].to_s
      if COMPARATORS_NEEDING_NUMERIC_FIDELITY.include?(op)
        return "where clause on #{field.inspect} uses op #{op.inspect} against a LITERAL value — gt/gte/lt/lte need " \
               "real Json::Num-vs-Json::Str fidelity this generator can't recover from the exported IR " \
               "(WhereClause#to_h renders every literal through QuerySpecification.render_value's own .to_s)"
      end
      return nil if COMPARATORS_EXEMPT_FROM_LITERAL_TYPING.include?(op)
      return nil if kind == :string

      "where clause on #{field.inspect} uses op #{op.inspect} against a LITERAL value whose target field doesn't " \
        "reduce to a plain JSON string (kind: #{kind}) — its true wire type can't be recovered from the exported IR"
    end

    # A whole declared query's own eligibility. `nil` means every
    # `emit_query_table` needs to fully bake this query in; a String
    # names the first reason (top-level option, or where clause) that
    # disqualifies it.
    def query_skip_reason(query, aggregate, value_objects_by_name)
      return "declares order_by, which this generator's query codegen doesn't implement — sorting is out of scope " \
             "for the field-comparator subset it covers (see rust/project/queries.rb's own header)" if query[:order_by]
      return "declares limit, out of scope for the same reason order_by is" if query[:limit]

      extras = %i[offset cursor consistency freshness authorization null_semantics inspection].select { |k| query[k] }
      return "declares #{extras.join(', ')}, out of scope for the same reason order_by is" if extras.any?
      return "declares use_index, out of scope for the same reason order_by is" if Array(query[:index_hints]).any?

      return "declares no where clauses at all — nothing for filter_entries to bake in" if Array(query[:wheres]).empty?

      query[:wheres].each do |where|
        reason = query_where_skip_reason(where, aggregate, value_objects_by_name)
        return reason if reason
      end

      nil
    end

    # `query_skip_reason` already returned `nil` for this query — every
    # where clause is either Symbol-valued (an `arg:`) or a safely-typed
    # literal (a `literal:`), never both, matching `kernel/named_query.rs`'s
    # own `QueryConditionValue` two-variant shape exactly.
    def query_conditions(query)
      query[:wheres].map do |where|
        raw_value = where[:value].to_s
        symbol = raw_value.start_with?(":")
        {
          field: where[:field].to_s,
          op: where[:op].to_s,
          arg: symbol ? raw_value.delete_prefix(":") : nil,
          literal: symbol ? nil : raw_value,
        }
      end
    end

    # `where[:op]` (one of `Hecksagain::QuerySpecification::Common::
    # COMPARATORS`, grammar-validated at bluebook declare time —
    # `admits: "Vocabulary::QueryComparator"`) to its Rust `QueryComparator`
    # variant name — the exact eight `query_comparators.rs` itself declares.
    QUERY_COMPARATOR_VARIANTS = {
      "eq" => "Eq", "ne" => "Ne", "gt" => "Gt", "gte" => "Gte",
      "lt" => "Lt", "lte" => "Lte", "in" => "In", "contains" => "Contains",
    }.freeze

    def query_comparator_variant(op)
      QUERY_COMPARATOR_VARIANTS.fetch(op) do
        raise "unknown query comparator #{op.inspect} — query_comparator_variant doesn't cover this shape " \
              "(grammar-validated at declare time, so this should be unreachable for a real declared query)"
      end
    end

    def emit_query_condition_value(condition)
      if condition[:arg]
        "crate::kernel::QueryConditionValue::Arg(#{condition[:arg].inspect})"
      else
        "crate::kernel::QueryConditionValue::Literal(#{condition[:literal].inspect})"
      end
    end

    def emit_query_condition(condition)
      comparator_expr = "crate::kernel::query_comparators::QueryComparator::#{query_comparator_variant(condition[:op])}"
      "crate::kernel::QueryCondition { field: #{condition[:field].inspect}, comparator: #{comparator_expr}, " \
        "value: #{emit_query_condition_value(condition)} },"
    end

    def emit_query_def(query_def)
      conditions = query_def[:conditions].map { |c| "        #{emit_query_condition(c)}" }.join("\n")
      <<~RUST.rstrip
        crate::kernel::QueryDef {
            verb: #{query_def[:verb].inspect},
            aggregate: #{query_def[:aggregate].inspect},
            conditions: &[
        #{conditions}
            ],
        },
      RUST
    end

    # The exact dedented text of `rust/src/exemplar/queries.rs`'s own
    # `TMPL:query_table` placeholder ROW — `Exemplar.render`'s substitution
    # is a literal substring match (its own header: "never a regex"), so
    # this has to reproduce that file's exact spacing, not just its shape.
    QUERY_TABLE_ROW_PLACEHOLDER = <<~RUST.rstrip
      crate::kernel::QueryDef {
          verb: "tmpl_verb",
          aggregate: "tmpl_aggregate",
          conditions: &[
              crate::kernel::QueryCondition {
                  field: "tmpl_field",
                  comparator: crate::kernel::query_comparators::QueryComparator::Eq,
                  value: crate::kernel::QueryConditionValue::Literal("tmpl_literal"),
              },
          ],
      },
    RUST

    # ── THE QUERY TABLE — `kernel::named_query::run`'s own static data,
    # `Runtime::QueryInterpreter#interpret` ported to generated `QueryDef`
    # rows a hand-written, generic function walks (kernel/named_query.rs),
    # the SAME "compile shapes, interpret behavior" split
    # `emit_policy_table`/`emit_process_manager_table` (reactions.rb)
    # already hold to. One row per query `query_skip_reason` (queries.rb,
    # above) let through — a skipped query simply has no row here at all,
    # the same "absent, not wrong" shape an unrouted command's own missing
    # registry entry already is.
    def emit_query_table(query_defs)
      rows = query_defs.map { |q| emit_query_def(q) }
      Exemplar.render("query_table", QUERY_TABLE_ROW_PLACEHOLDER => rows.join("\n"))
    end
  end
end
