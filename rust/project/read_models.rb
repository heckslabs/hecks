module RustProjection
  module Projector
    module_function

    # ── READ MODEL CODEGEN — the subset of a declared `report "X" do
    # ... end` block (IR::ReadModel — the `read_model` construct;
    # `report` is the language's own word for it, per syntax.bluebook's
    # `was: "read_model"`) expressible as: a ROOT aggregate fetched by
    # its own reference id, plus one or more OTHER aggregate heads found
    # by scanning and matching a REFERENCE FIELD back to an
    # already-projected root/sibling row, PLUS (as of 2026-08-11) a
    # declared `where`/`order_by`/`limit` on the ONE eligible many-side
    # head. Exactly `kernel/repository.rs`'s existing `AggregateScan`/
    # `filter_entries` scan primitive (`AggregateScan::scan`/
    # `filter_entries`, both reused directly — no new kernel scanning or
    # filtering primitive was needed) plus a hand-written matcher and
    # sorter (`kernel/read_model.rs`) that walks it the same "compile
    # shapes, interpret behavior" way `named_query.rs` already walks a
    # generated `QUERIES` table.
    #
    # GROUND TRUTH: `Runtime::ReadModelInterpreter#project`
    # (lib/hecksagain/runtime/read_model_interpreter.rb), read directly —
    # resolve the root by id, walk every declared head ROOT-FIRST for
    # COMPUTATION regardless of `include` order (a real, once-live bug:
    # a many-side head declared before its own root silently matched
    # against an empty `projected` and came back too small — see
    # `kernel/read_model.rs`'s own header for the full citation), match
    # every OTHER head's own reference attributes against whichever
    # heads are already in `projected` (applying `Ports::Query::InMemory.
    # execute` to the ONE eligible head's own rows the moment they're
    # computed, before they join `projected` — `model.filtered_head_name`
    # says which one), then materialize in DECLARED order for the OUTPUT
    # even though the computation above needed root-first.
    #
    # THE WIRE FORMAT USED TO STRUCTURALLY EXCLUDE where/order_by/limit —
    # `IR::ReadModel#to_h` never serialized them at all, so there was no
    # data here to bake a filter/sort/cap from no matter how this
    # generator was written. That changed 2026-08-11: `IR::ReadModel#to_h`
    # now spells `wheres`/`order_by`/`limit` explicitly, the same
    # mechanism `IR::Query#to_h` already used (`lib/hecksagain/bluebook/
    # ir/read_model.rb`'s own comment has the full history) — so this
    # generator now reads real filter/sort/cap data off the canonical
    # `ir.json` for the first time, and does something with it, for the
    # ONE eligible head `IR::ReadModel#filtered_head_name` already names
    # (`seal_query_options`'s own "options apply to a single collection"
    # rule — read directly in `lib/hecksagain/bluebook/dsl/
    # read_model_builder.rb` — means there is never ambiguity about which
    # head where/order_by/limit apply to; this generator trusts that
    # invariant the same way the Ruby interpreter does, rather than
    # re-deriving or re-checking it).
    #
    # WHAT THIS STILL DELIBERATELY DOES NOT COVER, AND WHY — read together
    # with `read_model_skip_reason` below:
    #
    #   `offset`/`cursor`/`consistency`/`authorization` (TenantScope) /
    #   `null_semantics` beyond the default/`inspection` — real
    #   capabilities `Ports::Query::InMemory`/`Ports::Query::Ordering`/
    #   `TenantScope` implement that this generator does not port, the
    #   SAME boundary `queries.rb` already draws for a declared AGGREGATE
    #   query's own `order_by`/`limit`/etc (that file's own header),
    #   applied consistently here now that where/order_by/limit
    #   themselves have crossed over. `freshness`/`use_index` are NOT in
    #   this list — see `READ_MODEL_BARE_KEYS` below for why tolerating
    #   them is honest, not a shortcut.
    #
    #   A `where`/`order_by` whose own field this generator can't safely
    #   express — a hop through a reference, an entity-scoped field, a
    #   `list_of` field, a multi-member non-numeric value object, or (for
    #   `where` specifically) a LITERAL comparator value whose true JSON
    #   type can't be recovered from the exported IR. Reuses `queries.rb`'s
    #   own `query_field_kind`/`query_where_skip_reason` wholesale, against
    #   the ELIGIBLE HEAD's own aggregate rather than the read model's root
    #   — the identical reasoning, just aimed at a different aggregate (see
    #   `read_model_options_content_skip_reason` below).
    #
    #   `TenantScope` (an `authorize policy, tenant: :field` boundary) —
    #   covered by the options-content check above (a declared `authorize`
    #   survives into `extra_options_to_h`, so any read model declaring one
    #   is already excluded). No real corpus read model declares one today
    #   (confirmed by reading all three declarations directly — see
    #   `bin/rust_coverage`'s own ALLOWLIST entry for this generator).
    #
    #   Adapter-native `query_read_model` pushdown (Postgres/SQL) — this
    #   kernel has no SQL adapter at all, the same structural N/A
    #   `queries.rb`'s own header and the era/lineage gap already
    #   establish for this codebase; `kernel/read_model.rs`'s in-process
    #   loop is the only path, matching Ruby's own in-process fallback
    #   (`ReadModelInterpreter#project`'s `unless rootless ||
    #   model.group_by.any?` early-return never fires for anything this
    #   generator admits, since none of it is rootless or group_by'd
    #   either — see below). This is also why tolerating `freshness`/
    #   `use_index` is honest rather than a shortcut: neither is ever READ
    #   by the in-memory interpreter path this kernel matches — both exist
    #   solely to steer an adapter's OWN native pushdown, which is
    #   structurally absent here regardless.
    #
    #   `rootless` read models and `group_by` — features that exist on
    #   this codebase's OWN `main` branch (a later `ReadModelInterpreter`
    #   than the one this branch carries), not on `feat/rust-projection`
    #   at all: THIS branch's `IR::ReadModel` has no `reference_target`-
    #   nilable/`group_by` concept for a bluebook author to even declare,
    #   so there is structurally nothing here to skip — noted for a
    #   future reader diffing this generator against a newer
    #   `read_model_interpreter.rb`, not a corner this generator cuts
    #   today.
    #
    #   `freshness`/`use_index` ARE tolerated (not disqualifying) — the
    #   only two of the eight generic options that are. Neither is ever
    #   read by `ReadModelInterpreter#project`'s in-memory path (see the
    #   pushdown paragraph above), so their presence changes nothing about
    #   what this generator can honestly compute; refusing on them anyway
    #   would be refusing a real corpus read model (`Banking::
    #   ComplianceDashboard` declares both) for a reason that has no
    #   bearing on correctness.
    READ_MODEL_BARE_KEYS = %i[name description reference_name reference_target query_name aggregate_heads
                              wheres order_by limit freshness index_hints].freeze

    # One declared read model's own eligibility — `nil` (clean) or a
    # specific, honest reason string, the same "one gate every other
    # function answers to" shape `queries.rb`'s own `query_skip_reason`
    # already holds to.
    def read_model_skip_reason(read_model, aggregates_by_name, unsupported_names)
      extra = read_model.keys.map(&:to_sym) - READ_MODEL_BARE_KEYS
      return read_model_options_skip_reason(extra) if extra.any?

      heads = read_model[:aggregate_heads]
      root = heads.find { |head| head[:aggregate].to_s == read_model[:reference_target].to_s }
      return "declares reference_to #{read_model[:reference_target]}, but includes no matching aggregate head — " \
             "nothing for this generator's own root fetch to key off (every real corpus read model includes its " \
             "own reference target; this generator refuses rather than guess at a root-less shape it doesn't cover)" unless root

      heads.each do |head|
        reason = read_model_head_skip_reason(head, aggregates_by_name, unsupported_names)
        return reason if reason
      end

      read_model_options_content_skip_reason(read_model, aggregates_by_name)
    end

    def read_model_options_skip_reason(extra)
      "declares #{extra.map(&:to_s).sort.join(', ')} — out of scope for this generator: offset/cursor/" \
        "consistency/authorization(TenantScope)/null_semantics beyond the default/inspection are real " \
        "capabilities Ports::Query::InMemory/Ports::Query::Ordering/TenantScope implement that this generator " \
        "does not port (this file's own header has the full argument, the same boundary queries.rb already " \
        "draws for a declared AGGREGATE query); freshness/use_index are never disqualifying on their own — " \
        "neither is read by the in-memory interpreter path this kernel matches"
    end

    # `IR::ReadModel#filtered_head_name`, ported directly — trusts the
    # SAME invariant it does (`ReadModelBuilder#seal_query_options`
    # already refuses ambiguity — zero or several many-side heads with
    # options declared — at bluebook declare time), so this doesn't
    # re-derive or re-check it either: the first many-side head IS the
    # eligible one whenever any option is declared at all.
    def read_model_filtered_head_as(read_model)
      declared = Array(read_model[:wheres]).any? || read_model[:order_by] || read_model[:limit] ||
                 read_model[:offset] || read_model.dig(:authorization, :tenant)
      return nil unless declared

      read_model[:aggregate_heads].find { |head| head[:many] }&.fetch(:as)
    end

    # The eligible head's own where/order_by/limit, checked for real
    # generability — `nil` (clean, including "nothing declared at all")
    # or a specific reason. Reuses `queries.rb`'s own `query_field_kind`/
    # `query_where_skip_reason` wholesale, aimed at the ELIGIBLE HEAD's
    # own aggregate (`CardPayment`, for `ComplianceDashboard`) rather
    # than the read model's root (`Account`) — the where/order_by
    # this generator ever bakes in are about the eligible collection's
    # own attributes, never the root's.
    def read_model_options_content_skip_reason(read_model, aggregates_by_name)
      eligible_as = read_model_filtered_head_as(read_model)
      return nil unless eligible_as

      head = read_model[:aggregate_heads].find { |h| h[:as].to_s == eligible_as.to_s }
      aggregate = aggregates_by_name[head[:aggregate]]
      value_objects_by_name = aggregate[:value_objects].to_h { |vo| [vo[:name], vo] }

      Array(read_model[:wheres]).each do |where|
        reason = query_where_skip_reason(where, aggregate, value_objects_by_name)
        return "eligible head #{head[:aggregate]}'s own #{reason}" if reason
      end

      order_reason = read_model_order_by_skip_reason(read_model[:order_by], aggregate, value_objects_by_name)
      return order_reason if order_reason

      read_model_limit_skip_reason(read_model[:limit])
    end

    def read_model_order_by_skip_reason(order_by, aggregate, value_objects_by_name)
      return nil unless order_by

      field = order_by[:field].to_s
      kind = query_field_kind(aggregate, field, value_objects_by_name)
      return nil if %i[string number].include?(kind)

      "declares order_by on #{field.inspect} — this generator can only sort a field that reduces to a plain " \
        "JSON string or number (kind: #{kind}); a hop through a reference, an entity-scoped field, a list_of " \
        "field, or a multi-member non-numeric value object can't be compared generically"
    end

    # `limit`'s own literal value rides the wire through `QuerySpecification.
    # render_value` (`.to_s` for anything that isn't a Symbol), so a real
    # Integer literal ("5") and a genuinely non-numeric literal are only
    # told apart here, the same "recover the true type or refuse" caution
    # `queries.rb`'s own literal-comparator reasoning already holds to — a
    # Symbol arg (":page_size") needs no such check, it resolves from real,
    # correctly-typed wire args at dispatch time.
    def read_model_limit_skip_reason(limit)
      return nil unless limit

      raw = limit[:value].to_s
      return nil if raw.start_with?(":") || raw.match?(/\A-?\d+\z/)

      "declares limit #{raw.inspect} — not a literal integer or a caller-bound Symbol arg, so this generator " \
        "can't compile a real limit count from it"
    end

    def read_model_head_skip_reason(head, aggregates_by_name, unsupported_names)
      target = aggregates_by_name[head[:aggregate]]
      return "includes #{head[:aggregate]}, which this domain never declares" unless target
      return "includes #{head[:aggregate]}, which this generator couldn't itself generate " \
             "(unsupported attribute type — see this domain's own aggregate-level manifest entry)" if unsupported_names.include?(head[:aggregate])

      nil
    end

    # `head_aggregate`'s own reference attributes, each paired with the
    # bare aggregate name it targets — `Runtime::ReadModelInterpreter#
    # reference_fields`, read directly: `aggregate.attributes.select {
    # attribute.reference? && attribute.type.target_name == target.to_s
    # }.map(&:name)`, just not narrowed to one `target` at a time the way
    # Ruby's own runtime re-derives it per candidate `source` — baked in
    # ONCE per head at codegen time instead, since this compiled kernel
    # has no runtime attribute-type reflection the way a live Ruby
    # `IR::Attribute` does. Every reference attribute is included
    # regardless of whether its OWN target is even a head on this same
    # read model (unlike Ruby, which only ever asks about a target that
    # IS already in `projected`) — harmless: `kernel/read_model.rs`'s own
    # matcher only ever finds a hit when the target genuinely is among
    # the heads already computed, so a reference field whose target
    # never appears here simply never contributes a match, the same
    # observable answer either way.
    def read_model_reference_fields(head_aggregate)
      head_aggregate[:attributes].filter_map do |attr|
        target = reference_target(attr[:type])
        next unless target

        { target: target, field: attr[:name] }
      end
    end

    def emit_reference_field(domain_name, reference_field)
      qualified_target = "#{domain_name}::#{reference_field[:target]}"
      "crate::kernel::read_model::ReferenceField { target_aggregate: #{qualified_target.inspect}, " \
        "field: #{reference_field[:field].to_s.inspect} }"
    end

    # ONE declared `include`, compiled — `is_root` precomputed once here
    # (`head[:aggregate] == read_model[:reference_target]`) rather than
    # re-compared at runtime against a stored `reference_target` string
    # on every call, and `reference_fields` left EMPTY for the root: the
    # root is never matched by reference at all, it's fetched directly
    # by the caller's own id argument (`kernel/read_model.rs`'s own
    # `run`, mirroring `ReadModelInterpreter#project`'s own `if
    # head[:aggregate] == model.reference_target` branch).
    def emit_read_model_head(domain_name, head, is_root, aggregates_by_name)
      reference_fields = is_root ? [] : read_model_reference_fields(aggregates_by_name[head[:aggregate]])
      reference_fields_expr = reference_fields.map { |rf| emit_reference_field(domain_name, rf) }.join(", ")
      qualified_aggregate = "#{domain_name}::#{head[:aggregate]}"

      "crate::kernel::read_model::ReadModelHead { aggregate: #{qualified_aggregate.inspect}, " \
        "as_name: #{head[:as].to_s.inspect}, many: #{head[:many] ? 'true' : 'false'}, " \
        "is_root: #{is_root ? 'true' : 'false'}, reference_fields: &[#{reference_fields_expr}] }"
    end

    # A whole declared read model, compiled to the plain data
    # `emit_read_model_def` renders — `verb` is the "Domain.Name" wire
    # string `kernel/cli.rs`'s STRING-form "query" step matches a
    # read-model ask against (that file's own header on how it tells
    # this shape apart from a named/declared AGGREGATE query's
    # "Domain::Aggregate.Name" shape: the presence of "::" before the
    # first "."), using the read model's own DECLARED name — the same
    # convention `queries.rb`'s own `query_def[:verb]` already picked
    # for a named query, not the snake-cased `query_name` `Runtime::
    # Dispatcher#query` would ALSO accept (`bluebook.read_model(named)`
    # matches either spelling in Ruby; this generator only ever needs to
    # emit one, and picks the same style precedent already set).
    # `order_by`'s own compiled form — `descending` collapses Ruby's own
    # `direction.to_s == "desc"` test once, at codegen time, matching
    # `kernel/read_model.rs`'s own `ReadModelOrderBy`.
    def emit_read_model_order_by(order_by)
      descending = order_by[:direction].to_s == "desc" ? "true" : "false"
      "crate::kernel::read_model::ReadModelOrderBy { field: #{order_by[:field].to_s.inspect}, descending: #{descending} }"
    end

    # `limit`'s own compiled form — the identical Literal/Arg split
    # `queries.rb`'s own `emit_query_condition_value` already draws for a
    # where clause's own value, aimed at `ReadModelLimit` instead of
    # `QueryConditionValue`. `read_model_limit_skip_reason` already
    # confirmed a non-Arg value is a real literal integer, so `.to_i` here
    # never silently truncates anything it didn't already refuse.
    def emit_read_model_limit(limit)
      raw = limit[:value].to_s
      return "crate::kernel::read_model::ReadModelLimit::Arg(#{raw.delete_prefix(':').inspect})" if raw.start_with?(":")

      "crate::kernel::read_model::ReadModelLimit::Literal(#{raw.to_i})"
    end

    # A whole declared read model, compiled to the plain data
    # `emit_read_model_def` renders — `verb` is the "Domain.Name" wire
    # string `kernel/cli.rs`'s STRING-form "query" step matches a
    # read-model ask against (that file's own header on how it tells
    # this shape apart from a named/declared AGGREGATE query's
    # "Domain::Aggregate.Name" shape: the presence of "::" before the
    # first "."), using the read model's own DECLARED name — the same
    # convention `queries.rb`'s own `query_def[:verb]` already picked
    # for a named query, not the snake-cased `query_name` `Runtime::
    # Dispatcher#query` would ALSO accept (`bluebook.read_model(named)`
    # matches either spelling in Ruby; this generator only ever needs to
    # emit one, and picks the same style precedent already set).
    #
    # `filtered_head`/`conditions`/`order_by`/`limit` are only ever
    # populated when `read_model_filtered_head_as` names an eligible head
    # — `read_model_skip_reason` (via `read_model_options_content_skip_
    # reason`) already refused this read model entirely if that head's
    # own where/order_by/limit weren't genuinely generable, so by the time
    # this runs there is nothing left to check. `conditions` reuses
    # `queries.rb`'s own `query_conditions` wholesale — a where clause's
    # wire shape (`{field:, op:, value:}`) is identical whether it came
    # off a declared Query or a ReadModel's own `wheres`.
    def read_model_def(domain_name, read_model, aggregates_by_name)
      heads = read_model[:aggregate_heads].map do |head|
        is_root = head[:aggregate].to_s == read_model[:reference_target].to_s
        emit_read_model_head(domain_name, head, is_root, aggregates_by_name)
      end

      eligible_as = read_model_filtered_head_as(read_model)

      {
        verb: "#{domain_name}.#{read_model[:name]}",
        reference_name: read_model[:reference_name].to_s,
        heads: heads,
        filtered_head: eligible_as&.to_s,
        conditions: eligible_as ? query_conditions(read_model) : [],
        order_by: eligible_as && read_model[:order_by] ? emit_read_model_order_by(read_model[:order_by]) : nil,
        limit: eligible_as && read_model[:limit] ? emit_read_model_limit(read_model[:limit]) : nil,
      }
    end

    def emit_read_model_def(read_model_def)
      heads = read_model_def[:heads].map { |head| "        #{head}," }.join("\n")
      conditions = read_model_def[:conditions].map { |c| "        #{emit_query_condition(c)}" }.join("\n")
      filtered_head = read_model_def[:filtered_head] ? "Some(#{read_model_def[:filtered_head].inspect})" : "None"
      order_by = read_model_def[:order_by] ? "Some(#{read_model_def[:order_by]})" : "None"
      limit = read_model_def[:limit] ? "Some(#{read_model_def[:limit]})" : "None"

      <<~RUST.rstrip
        crate::kernel::read_model::ReadModelDef {
            verb: #{read_model_def[:verb].inspect},
            reference_name: #{read_model_def[:reference_name].inspect},
            heads: &[
        #{heads}
            ],
            filtered_head: #{filtered_head},
            conditions: &[
        #{conditions}
            ],
            order_by: #{order_by},
            limit: #{limit},
        },
      RUST
    end

    # The exact dedented text of `rust/src/exemplar/read_models.rs`'s own
    # `TMPL:read_model_table` placeholder ROW — `Exemplar.render`'s
    # substitution is a literal substring match, so this has to reproduce
    # that file's exact spacing, matching `queries.rb`'s own
    # `QUERY_TABLE_ROW_PLACEHOLDER` precedent exactly.
    READ_MODEL_TABLE_ROW_PLACEHOLDER = <<~RUST.rstrip
      crate::kernel::read_model::ReadModelDef {
          verb: "tmpl_verb",
          reference_name: "tmpl_reference_name",
          heads: &[
              crate::kernel::read_model::ReadModelHead {
                  aggregate: "tmpl_aggregate",
                  as_name: "tmpl_as_name",
                  many: true,
                  is_root: false,
                  reference_fields: &[
                      crate::kernel::read_model::ReferenceField { target_aggregate: "tmpl_target_aggregate", field: "tmpl_field" },
                  ],
              },
          ],
          filtered_head: Some("tmpl_as_name"),
          conditions: &[
              crate::kernel::QueryCondition {
                  field: "tmpl_field",
                  comparator: crate::kernel::query_comparators::QueryComparator::Eq,
                  value: crate::kernel::QueryConditionValue::Literal("tmpl_literal"),
              },
          ],
          order_by: Some(crate::kernel::read_model::ReadModelOrderBy { field: "tmpl_order_field", descending: true }),
          limit: Some(crate::kernel::read_model::ReadModelLimit::Literal(5)),
      },
    RUST

    # ── THE READ MODEL TABLE — `kernel::read_model::run`'s own static
    # data, `Runtime::ReadModelInterpreter#project` ported to generated
    # `ReadModelDef` rows a hand-written, generic function walks
    # (kernel/read_model.rs), the SAME "compile shapes, interpret
    # behavior" split `emit_query_table`/`emit_policy_table` already hold
    # to. One row per read model `read_model_skip_reason` (above) lets
    # through — a skipped one simply has no row here at all.
    def emit_read_model_table(read_model_defs)
      rows = read_model_defs.map { |rmd| emit_read_model_def(rmd) }
      Exemplar.render("read_model_table", READ_MODEL_TABLE_ROW_PLACEHOLDER => rows.join("\n"))
    end
  end
end
