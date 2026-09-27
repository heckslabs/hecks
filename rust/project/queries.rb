require_relative "skip_reason"

# Generates the Rust named-query table from the exported IR, with skip reasons.
module RustProjection
  module Projector
    module_function

    # Named-query codegen: a declared `query` whose where clauses compare one aggregate's own
    # fields becomes a `QueryDef` row, with its `order_by`/`offset`/`limit` carried alongside.
    #
    # `query_skip_reason` is the gate; a query it refuses gets no row, with the reason recorded.
    # Refused: cursor/consistency/freshness/inspection/use_index, order_by on a field that is not
    # a plain string or number, a limit/offset that is neither an integer literal nor a Symbol arg.
    #
    # Literal where values arrive through the exported IR as `value.to_s`, so an Integer and a
    # String literal are indistinguishable. gt/gte/lt/lte therefore never take a literal, eq/ne
    # take one only against a provably string-shaped field, and in/contains stringify anyway.
    # A Symbol value resolves from the typed wire args at dispatch, so it is always safe.
    COMPARATORS_NEEDING_NUMERIC_FIDELITY = %w[gt gte lt lte].freeze
    COMPARATORS_EXEMPT_FROM_LITERAL_TYPING = %w[in contains].freeze

    # The kind (`:string`, `:number`, `:other`, `:unknown`) a where/order_by `field` reduces to
    # on `aggregate`, mirroring `Ports::Query::InMemory#comparable`. Nested value-object
    # segments are walked; `:unknown` means the head is not one of the aggregate's own
    # attributes, which is also how a reference hop is detected.
    def query_field_kind(aggregate, field, value_objects_by_name)
      segments = field.to_s.split(".")
      head = segments.first
      rest = segments[1..] || []

      lifecycle_field = aggregate[:lifecycle] && aggregate[:lifecycle][:field]
      return rest.empty? ? :string : :unknown if lifecycle_field && lifecycle_field.to_s == head

      attr = aggregate[:attributes].find { |a| a[:name].to_s == head }
      return :unknown unless attr
      # A `list_of` field compares as an array, never a scalar a literal could target.
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

    # Mirrors `comparable` for a value object: a numeric member wins, a single member collapses
    # to its own kind, anything else stays a whole JSON object.
    def query_vo_collapse_kind(vo, value_objects_by_name)
      return :number if vo[:attributes].any? { |a| %w[Integer Float].include?(a[:type].to_s) }
      return query_type_kind(vo[:attributes].first[:type].to_s, [], value_objects_by_name) if vo[:attributes].size == 1

      :other
    end

    # Resolves a `/` reference-hop field (`member/sponsor/standing`) against `aggregates_by_name`.
    # Returns nil for a non-hop or an unresolvable one; otherwise
    # `{via_field:, target_aggregate:, through:, target:, inner_field:}`, where `through` holds
    # the steps after the first and `target` is the last aggregate the inner field is checked on.
    HOP_CHAIN_LIMIT = 8 # Hecks::QuerySpecification::HopPath::MAX_HOPS
    def query_hop_plan(aggregate, field, aggregates_by_name)
      segments = field.to_s.split("/")
      return nil if segments.size < 2 || segments.size - 1 > HOP_CHAIN_LIMIT

      steps = []
      current = aggregate
      segments[0..-2].each do |segment|
        via_attr = current[:attributes].find { |a| a[:name].to_s == segment }
        return nil unless via_attr && reference_type?(via_attr[:type])

        target_name = reference_target(via_attr[:type])
        target = aggregates_by_name[target_name]
        return nil unless target

        steps << { via_field: segment, target_aggregate: target_name }
        current = target
      end

      { via_field: steps.first[:via_field], target_aggregate: steps.first[:target_aggregate], through: steps.drop(1),
        target: current, inner_field: segments.last }
    end

    # One where clause's eligibility: nil when generable, otherwise a skip reason.
    def query_where_skip_reason(where, aggregate, value_objects_by_name)
      field = where[:field].to_s
      kind = query_field_kind(aggregate, field, value_objects_by_name)
      if kind == :unknown
        construct = field.include?("/") ? "reference_hop_where" : "where_unrecognized_field"
        return skip(construct, "where clause on #{field.inspect} isn't a recognized attribute of this aggregate — a hop through a " \
               "reference, an entity-scoped field, or simply undeclared here; cross-aggregate joins are read_model " \
               "territory, not this generator's job")
      end

      raw_value = where[:value].to_s
      return nil if raw_value.start_with?(":") # Symbol-valued — resolved from real, correctly-typed wire args at dispatch time

      op = where[:op].to_s
      unless QUERY_COMPARATOR_VARIANTS.key?(op)
        return skip("where_none_in_state", "where clause on #{field.inspect} uses op #{op.inspect} — Vocabulary::QueryComparator admits it, " \
               "and rust/src/kernel/query_comparators.rs's own QueryComparator::NoneInState variant now exists " \
               "and is proven correct (item #9, whole-project table-unification survey) — but no generated " \
               "domain has any way to hand it a cross-domain search list at the call site (named_query::run's " \
               "own thin `run_cross_domain([])` wrapper is what every generated QUERIES table actually calls), " \
               "so generating this condition today would silently answer every row 'true' rather than a real " \
               "anti-join — deliberately left ungenerated until a real cross-domain-search call site exists, " \
               "the same honest-refusal-over-silently-wrong choice this generator makes everywhere else")
      end
      if COMPARATORS_NEEDING_NUMERIC_FIDELITY.include?(op)
        return nil if kind == :number

        return skip("where_literal", "where clause on #{field.inspect} uses op #{op.inspect} against a LITERAL value whose target " \
               "field doesn't reduce to a plain JSON number (kind: #{kind}) — gt/gte/lt/lte only mean anything " \
               "against a number (query_comparators.rs's own `ordered?` gate)")
      end
      return nil if COMPARATORS_EXEMPT_FROM_LITERAL_TYPING.include?(op)
      return nil if kind == :string
      return nil if kind == :number

      skip("where_literal", "where clause on #{field.inspect} uses op #{op.inspect} against a LITERAL value whose target field doesn't " \
                            "reduce to a plain JSON string (kind: #{kind}) — its true wire type can't be recovered from the exported IR")
    end

    # A whole query's eligibility: nil when `emit_query_table` can bake it in, otherwise the
    # first skip reason. order_by/limit content is checked last so the reason reported is the
    # real remaining one.
    def query_skip_reason(query, aggregate, value_objects_by_name, aggregates_by_name = {})
      extras = %i[cursor consistency freshness inspection].select { |k| query[k] }
      return skip(extras.first, "declares #{extras.join(', ')} — out of scope for this generator (rust/project/queries.rb's own " \
                                "header has the full argument)") if extras.any?
      return skip("index_hints", "declares use_index, out of scope for the same reason the extras above are") if Array(query[:index_hints]).any?

      # A query with no where clause but a declared tenant still has logic: the tenant check.
      declared_tenant = query[:authorization] && query[:authorization][:tenant]
      return skip("no_wheres", "declares no where clauses at all — nothing for filter_entries to bake in") if Array(query[:wheres]).empty? && !declared_tenant

      # A single hop is generated via `kernel::read_model::apply_reference_hops`; its inner
      # clause is checked against the target aggregate. A longer chain is refused.
      query[:wheres].each do |where|
        hop = query_hop_plan(aggregate, where[:field].to_s, aggregates_by_name)
        if hop
          target_value_objects_by_name = hop[:target][:value_objects].to_h { |vo| [vo[:name], vo] }
          reason = query_where_skip_reason(where.merge(field: hop[:inner_field]), hop[:target], target_value_objects_by_name)
          return reskip(reason, "hop through #{hop[:via_field]} to #{hop[:target_aggregate]}'s own #{reason}") if reason

          next
        end

        reason = query_where_skip_reason(where, aggregate, value_objects_by_name)
        return reason if reason
      end

      auth_reason = declared_authorization_skip_reason(query[:authorization], aggregate, value_objects_by_name)
      return auth_reason if auth_reason

      order_reason = declared_order_by_skip_reason(query[:order_by], aggregate, value_objects_by_name)
      return order_reason if order_reason

      offset_reason = declared_offset_skip_reason(query[:offset])
      return offset_reason if offset_reason

      declared_limit_skip_reason(query[:limit])
    end

    # `authorize policy, tenant: :field`: no tenant is a no-op, as in `TenantScope.apply`;
    # a tenant field gets the same check as a where clause on it.
    def declared_authorization_skip_reason(authorization, aggregate, value_objects_by_name)
      tenant = authorization && authorization[:tenant]
      return nil unless tenant

      synthetic_where = { field: tenant, op: "eq", value: ":#{tenant}" }
      reason = query_where_skip_reason(synthetic_where, aggregate, value_objects_by_name)
      reason && skip("authorization", reason)
    end

    # Whether `order_by` names a field that reduces to a plain string or number.
    def declared_order_by_skip_reason(order_by, aggregate, value_objects_by_name)
      return nil unless order_by

      field = order_by[:field].to_s
      kind = query_field_kind(aggregate, field, value_objects_by_name)
      return nil if %i[string number].include?(kind)

      skip("order_by", "declares order_by on #{field.inspect} — this generator can only sort a field that reduces to a plain " \
                       "JSON string or number (kind: #{kind}); a hop through a reference, an entity-scoped field, a list_of " \
                       "field, or a multi-member non-numeric value object can't be compared generically")
    end

    # `limit` arrives through `render_value` as text, so an integer literal is told apart from a
    # non-numeric one here; a Symbol arg resolves from typed wire args at dispatch.
    def declared_limit_skip_reason(limit)
      return nil unless limit

      raw = limit[:value].to_s
      return nil if raw.start_with?(":") || raw.match?(/\A-?\d+\z/)

      skip("limit", "declares limit #{raw.inspect} — not a literal integer or a caller-bound Symbol arg, so this generator " \
                    "can't compile a real limit count from it")
    end

    # `offset` has the same wire shape as `limit`; kept separate so the reason names "offset".
    def declared_offset_skip_reason(offset)
      return nil unless offset

      raw = offset[:value].to_s
      return nil if raw.start_with?(":") || raw.match?(/\A-?\d+\z/)

      skip("offset", "declares offset #{raw.inspect} — not a literal integer or a caller-bound Symbol arg, so this generator " \
                     "can't compile a real offset count from it")
    end

    # `order_by`'s compiled form. `null_semantics` is a sibling key in the IR, passed in
    # separately and folded into the `OrderBy` struct.
    def emit_query_order_by(order_by, null_semantics = nil)
      descending = order_by[:direction].to_s == "desc" ? "true" : "false"
      "crate::kernel::query_ordering::OrderBy { field: #{order_by[:field].to_s.inspect}, descending: #{descending}, " \
        "nulls: #{null_semantics_variant(null_semantics)} }"
    end

    # An unrecognized `nulls` mode falls back to native ordering, as in
    # `QuerySpecification::Common::NullPolicy.order`; the default never reaches the wire.
    NULLS_MODE_VARIANTS = { "first" => "First", "last" => "Last" }.freeze

    def null_semantics_variant(null_semantics)
      mode = null_semantics && null_semantics[:mode].to_s
      "crate::kernel::query_ordering::NullsMode::#{NULLS_MODE_VARIANTS.fetch(mode, 'Native')}"
    end

    # `limit`'s compiled form; `declared_limit_skip_reason` has already vetted the literal.
    def emit_query_limit(limit)
      raw = limit[:value].to_s
      return "crate::kernel::query_ordering::Limit::Arg(#{raw.delete_prefix(':').inspect})" if raw.start_with?(":")

      "crate::kernel::query_ordering::Limit::Literal(#{raw.to_i})"
    end

    # `offset`'s compiled form: `Offset` aliases `Limit`, so this reuses `emit_query_limit`
    # and respells the type so the generated code reads naturally.
    def emit_query_offset(offset) = emit_query_limit(offset).sub("query_ordering::Limit::", "query_ordering::Offset::")

    # Where clauses as `arg:` (Symbol value) or `literal:` conditions. A string literal is
    # decoded with `Literal.read`; the raw wire text still carries its quote marks and would
    # silently match nothing.
    def query_conditions(query)
      query[:wheres].map do |where|
        raw_value = where[:value].to_s
        symbol = raw_value.start_with?(":")
        {
          field: where[:field].to_s,
          op: where[:op].to_s,
          arg: symbol ? raw_value.delete_prefix(":") : nil,
          literal: symbol ? nil : Hecks::Literal.read(raw_value),
        }
      end
    end

    # `Runtime::TenantScope.apply`'s synthetic `field == args[tenant]` clause, appended at
    # codegen time. Query-only: read models still refuse `authorize`.
    def query_conditions_with_authorization(query)
      tenant = query[:authorization] && query[:authorization][:tenant]
      return query_conditions(query) unless tenant

      query_conditions(query) << { field: tenant.to_s, op: "eq", arg: tenant.to_s, literal: nil }
    end

    # Splits a query's where clauses into local conditions (plus the tenant clause) and
    # single-hop `ReferenceHopCondition`s.
    def query_conditions_and_hops(domain_name, query, aggregate, aggregates_by_name)
      local, hops = Array(query[:wheres]).partition { |where| query_hop_plan(aggregate, where[:field].to_s, aggregates_by_name).nil? }
      [query_conditions_with_authorization(query.merge(wheres: local)),
       read_model_hop_conditions(domain_name, hops, aggregate, aggregates_by_name)]
    end

    # `TenantAuth`'s compiled form; nil without a declared tenant. `policy` is carried, not
    # enforced, as in Ruby.
    def emit_query_authorization(query_name, authorization)
      tenant = authorization && authorization[:tenant]
      return nil unless tenant

      policy = authorization[:policy]
      "crate::kernel::named_query::TenantAuth { query_name: #{query_name.to_s.inspect}, tenant_field: #{tenant.to_s.inspect}, policy: #{policy.to_s.inspect} }"
    end

    # Maps a where `op` to its Rust `QueryComparator` variant. `none_in_state` is omitted on
    # purpose: no generated call site can supply a cross-domain search list, so it would
    # answer every row `true` (see `query_where_skip_reason`).
    QUERY_COMPARATOR_VARIANTS = {
      "eq" => "Eq", "ne" => "Ne", "gt" => "Gt", "gte" => "Gte",
      "lt" => "Lt", "lte" => "Lte", "in" => "In", "contains" => "Contains",
    }.freeze

    def query_comparator_variant(op)
      QUERY_COMPARATOR_VARIANTS.fetch(op) do
        raise "unknown query comparator #{op.inspect} — query_comparator_variant doesn't cover this shape " \
              "(grammar-validated at declare time, so this should be unreachable for a real declared query; " \
              "query_where_skip_reason should have already skipped it with an honest reason)"
      end
    end

    def emit_query_condition_value(condition)
      if condition[:arg]
        "crate::kernel::QueryConditionValue::Arg(#{condition[:arg].inspect})"
      elsif condition[:literal].is_a?(Numeric)
        # Only a numeric-kind target reaches here with a Numeric literal, so its class picks
        # the variant.
        "crate::kernel::QueryConditionValue::NumericLiteral(#{Float(condition[:literal]).inspect})"
      else
        "crate::kernel::QueryConditionValue::Literal(#{condition[:literal].inspect})"
      end
    end

    def emit_query_condition(condition)
      comparator_expr = "crate::kernel::query_comparators::QueryComparator::#{query_comparator_variant(condition[:op])}"
      "crate::kernel::QueryCondition { field: #{condition[:field].inspect}, comparator: #{comparator_expr}, " \
        "value: #{emit_query_condition_value(condition)} },"
    end

    # `order_by`/`offset`/`limit`/`authorization` are nil unless the query declared them.
    def emit_query_def(query_def)
      conditions = query_def[:conditions].map { |c| "        #{emit_query_condition(c)}" }.join("\n")
      reference_hop_conditions = Array(query_def[:reference_hop_conditions]).map { |h| "        #{emit_reference_hop_condition(h)}" }.join("\n")
      order_by = query_def[:order_by] ? "Some(#{query_def[:order_by]})" : "None"
      offset = query_def[:offset] ? "Some(#{query_def[:offset]})" : "None"
      limit = query_def[:limit] ? "Some(#{query_def[:limit]})" : "None"
      authorization = query_def[:authorization] ? "Some(#{query_def[:authorization]})" : "None"

      <<~RUST.rstrip
        crate::kernel::QueryDef {
            verb: #{query_def[:verb].inspect},
            aggregate: #{query_def[:aggregate].inspect},
            conditions: &[
        #{conditions}
            ],
            reference_hop_conditions: &[
        #{reference_hop_conditions}
            ],
            order_by: #{order_by},
            offset: #{offset},
            limit: #{limit},
            authorization: #{authorization},
        },
      RUST
    end

    # Text of the `TMPL:query_table` row in `rust/src/exemplar/queries.rs`; `Exemplar.render`
    # substitutes it as an exact substring, so the spacing must match.
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
          reference_hop_conditions: &[
              crate::kernel::read_model::ReferenceHopCondition {
                  via_field: "tmpl_via_field",
                  target_aggregate: "tmpl_target_aggregate",
                  through: &[crate::kernel::read_model::HopStep { via_field: "tmpl_via_field", target_aggregate: "tmpl_target_aggregate" }],
                  inner_field: "tmpl_inner_field",
                  inner_comparator: crate::kernel::query_comparators::QueryComparator::Eq,
                  inner_value: crate::kernel::QueryConditionValue::Literal("tmpl_literal"),
              },
          ],
          order_by: Some(crate::kernel::query_ordering::OrderBy { field: "tmpl_order_field", descending: true, nulls: crate::kernel::query_ordering::NullsMode::Last }),
          offset: Some(crate::kernel::query_ordering::Offset::Literal(1)),
          limit: Some(crate::kernel::query_ordering::Limit::Literal(5)),
          authorization: Some(crate::kernel::named_query::TenantAuth { query_name: "tmpl_query_name", tenant_field: "tmpl_tenant_field", policy: "tmpl_policy" }),
      },
    RUST

    # The `QUERIES` table `kernel::named_query::run` walks, one row per generable query, then
    # the authorization-assignments constant and the entity-query table.
    def emit_query_table(query_defs)
      entity_defs, aggregate_defs = query_defs.partition { |q| q[:entity] }
      rows = aggregate_defs.map { |q| emit_query_def(q) }
      "#{Exemplar.render('query_table', QUERY_TABLE_ROW_PLACEHOLDER => rows.join("\n"))}\n" \
        "#{emit_authorization_assignments(query_defs)}" \
        "#{emit_entity_query_table(entity_defs)}"
    end

    # The chapter-local verb `provides "authorization", assignments:` names, or nil.
    def provided_assignments(ir)
      Array(ir[:provides]).find { |row| row[:capability] == "authorization" && row[:key] == "assignments" }&.dig(:verb)
    end

    # The `AUTHORIZATION_ASSIGNMENTS` constant `kernel::check_role_via` reads; a merged union
    # carries its chapters' `assignments` flag with their defs.
    def emit_authorization_assignments(query_defs)
      verb = query_defs.find { |q| q[:assignments] }&.dig(:verb)
      value = verb ? "Some(#{verb.inspect})" : "None"
      "/// `provides \"authorization\", assignments:` — the query `kernel::check_role_via` reads; " \
        "`None` when no chapter here declares one.\n" \
        "pub const AUTHORIZATION_ASSIGNMENTS: Option<&str> = #{value};\n"
    end

    # `ENTITY_QUERIES`: declared `Aggregate.Entity.Query` rows for `named_query::run_entity`.
    def emit_entity_query_table(entity_defs)
      rows = entity_defs.map { |q| "#{emit_entity_query_def(q)}\n" }.join
      "/// Declared entity queries (`Aggregate.Entity.Query`) — `kernel::named_query::run_entity`.\n" \
        "pub const ENTITY_QUERIES: &[crate::kernel::named_query::EntityQueryDef] = &[\n#{rows}];\n"
    end

    def emit_entity_query_def(query_def)
      entity = query_def[:entity]
      conditions = query_def[:conditions].map { |c| "        #{emit_query_condition(c)}" }.join("\n")
      keys = entity[:identity_keys].map(&:inspect).join(", ")
      order_by = query_def[:order_by] ? "Some(#{query_def[:order_by]})" : "None"
      offset = query_def[:offset] ? "Some(#{query_def[:offset]})" : "None"
      limit = query_def[:limit] ? "Some(#{query_def[:limit]})" : "None"
      "crate::kernel::named_query::EntityQueryDef {\n    verb: #{query_def[:verb].inspect},\n    " \
        "aggregate: #{query_def[:aggregate].inspect},\n    list_field: #{entity[:list_field].inspect},\n    " \
        "parent_key: #{entity[:parent_key].inspect},\n    identity_keys: &[#{keys}],\n    conditions: &[\n#{conditions}\n    ],\n    " \
        "order_by: #{order_by},\n    offset: #{offset},\n    limit: #{limit},\n},"
    end

    # An entity query needs a list attribute holding the entity; tenant scope is not generated.
    # Its clauses are otherwise checked as on an aggregate query, against the entity's fields.
    def entity_query_skip_reason(query, entity, list_attr, value_objects_by_name)
      return skip("entity_query", "#{entity[:name]} is held in no list attribute on its aggregate — nothing to flatten") unless list_attr
      return skip("entity_query_authorization", "declares authorize — an entity query's tenant scope is not generated yet") if query[:authorization]

      query_skip_reason(query, entity, value_objects_by_name)
    end

    # `Hecks::Naming.snake`.
    def snake(text)
      text.to_s.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
    end

    # Builds and invariant-checks each value-object argument of a named query, as
    # `QueryInterpreter#normalize_args` does; the typed value is only a gate, the comparison
    # reads raw JSON. A closed set's `from_json` already refuses non-members, so it is not
    # invariant-checked. Only the aggregate's own value objects are typed.
    def query_arg_checks(query, mod_path, value_objects_by_name)
      query[:attributes].filter_map do |attr|
        next if attr[:list] || attr[:relationship]

        vo = value_objects_by_name[attr[:type]]
        next unless vo

        key   = rust_field(attr[:name])
        build = composite_from_json_expr(attr, value_objects_by_name, "x")
        check = vo[:closed_set] ? "" : ".check_invariants()?"
        "if let Some(x) = args.get(#{key.inspect}) { #{mod_path}::#{build}#{check}; }"
      end
    end

    # `check_query_args`, the gate `kernel/cli.rs` runs before `named_query::run`: one arm per
    # query with a typed argument, `Ok(())` otherwise.
    def emit_query_arg_check_table(query_defs)
      arms = query_defs.reject { |q| q[:arg_checks].empty? }.map do |q|
        lines = q[:arg_checks].map { |line| "            #{line}" }.join("\n")
        "        #{q[:verb].inspect} => {\n#{lines}\n            Ok(())\n        }"
      end
      <<~RUST
        /// C3.7 for a named query's own arguments — `query_arg_checks`
        /// (rust/project/queries.rb) has the full story.
        pub fn check_query_args(verb: &str, args: &crate::kernel::Json) -> Result<(), crate::kernel::Refusal> {
            match verb {
        #{arms.join("\n")}
                _ => Ok(()),
            }
        }
      RUST
    end
  end
end
