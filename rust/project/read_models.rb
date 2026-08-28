module RustProjection
  module Projector
    module_function

    # ── READ MODEL CODEGEN — the subset of a declared `report "X" do
    # ... end` block (ReadModel — the `read_model` construct;
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
    # (lib/hecks/runtime/read_model_interpreter.rb), read directly —
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
    # `ReadModel#to_h` never serialized them at all, so there was no
    # data here to bake a filter/sort/cap from no matter how this
    # generator was written. That changed 2026-08-11: `ReadModel#to_h`
    # now spells `wheres`/`order_by`/`limit` explicitly, the same
    # mechanism `Query#to_h` already used (`lib/hecks/bluebook/
    # ir/read_model.rb`'s own comment has the full history) — so this
    # generator now reads real filter/sort/cap data off the canonical
    # `ir.json` for the first time, and does something with it, for the
    # ONE eligible head `ReadModel#filtered_head_name` already names
    # (`seal_query_options`'s own "options apply to a single collection"
    # rule — read directly in `lib/hecks/bluebook/dsl/
    # read_model_builder.rb` — means there is never ambiguity about which
    # head where/order_by/limit apply to; this generator trusts that
    # invariant the same way the Ruby interpreter does, rather than
    # re-deriving or re-checking it).
    #
    # WHAT THIS STILL DELIBERATELY DOES NOT COVER, AND WHY — read together
    # with `read_model_skip_reason` below:
    #
    #   `cursor`/`consistency`/
    #   `inspection` — real
    #   capabilities `Ports::Query::InMemory`/`Ports::Query::Ordering`/
    #   `TenantScope` implement that this generator does not port, the
    #   SAME boundary `queries.rb` already draws for a declared AGGREGATE
    #   query's own `order_by`/`limit`/etc (that file's own header),
    #   applied consistently here now that where/order_by/limit
    #   themselves have crossed over. `freshness`/`use_index` are NOT in
    #   this list — see `READ_MODEL_BARE_KEYS` below for why tolerating
    #   them is honest, not a shortcut. `offset`/`null_semantics`/
    #   `authorization` used to be in this list too — Phase 10
    #   (equivalence-gap plan) ported all three, reusing `queries.rb`'s own
    #   `declared_offset_skip_reason`/`emit_query_order_by`'s own
    #   `null_semantics_variant`/`declared_authorization_skip_reason`
    #   directly (no read-model-specific content check needed for any of
    #   them — the exact same shapes/fallback rules apply whether the
    #   declaring construct was a Query or a ReadModel). `authorization`
    #   specifically has no real corpus read model to prove it against
    #   today (unlike the AGGREGATE-query port, which closed a real,
    #   previously-refused `Banking::SafeDepositBox.Rented`) — ADR 0041
    #   has the honest accounting of why it was ported anyway (the
    #   mechanism is byte-identical to the already-proven query path, not
    #   new design) and what's verified against instead (a purpose-built
    #   fixture).
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
    #   at all: THIS branch's `ReadModel` has no `reference_target`-
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
    # `group_by` is IN this list — merged in from `main`'s own rootless-
    # read-model work (see the long note above), which made `
    # ReadModel#to_h` spell `group_by:` UNCONDITIONALLY, the same
    # "always spell the key" move `wheres`/`order_by`/`limit` already
    # went through (this file's own header, above). So `group_by`'s mere
    # PRESENCE as a key is no longer a usable disqualifying signal — every
    # read model carries it now, `[]` when nothing was declared — and it
    # has to be checked by VALUE instead, explicitly, right below.
    READ_MODEL_BARE_KEYS = %i[name description reference_name reference_target query_name aggregate_heads
                              wheres order_by offset limit freshness index_hints group_by null_semantics
                              authorization count median_field].freeze

    # One declared read model's own eligibility — `nil` (clean) or a
    # specific, honest reason string, the same "one gate every other
    # function answers to" shape `queries.rb`'s own `query_skip_reason`
    # already holds to.
    def read_model_skip_reason(read_model, aggregates_by_name, unsupported_names)
      extra = read_model.keys.map(&:to_sym) - READ_MODEL_BARE_KEYS
      return read_model_options_skip_reason(extra) if extra.any?

      # A GENUINE `group_by` declaration (a non-empty value, not just the
      # key's own unconditional presence — see `READ_MODEL_BARE_KEYS`'s
      # own comment). Checked before the `reference_to`/root-fetch check
      # below on purpose — a rootless, `group_by`'d read model
      # (`AccountsByKind`) has no `reference_target` at all, and reporting
      # THAT as "no matching aggregate head" would be a true but
      # misleading reason next to the real, honest one this check gives
      # instead. Ported for the ONE real shape the corpus declares — a
      # SINGLE rootless head, group_by alone (no where/order/limit/
      # offset/count/median/authorize alongside it) — see
      # `group_by_skip_reason`.
      return group_by_skip_reason(read_model, aggregates_by_name, unsupported_names) if Array(read_model[:group_by]).any?

      heads = read_model[:aggregate_heads]
      root = heads.find { |head| head[:aggregate].to_s == read_model[:reference_target].to_s }
      return "declares reference_to #{read_model[:reference_target]}, but includes no matching aggregate head — " \
             "nothing for this generator's own root fetch to key off (every real corpus read model includes its " \
             "own reference target; this generator refuses rather than guess at a root-less shape it doesn't cover)" unless root

      heads.each do |head|
        reason = read_model_head_skip_reason(head, aggregates_by_name, unsupported_names)
        return reason if reason
      end

      reason = read_model_options_content_skip_reason(read_model, aggregates_by_name)
      return reason if reason

      aggregation_skip_reason(read_model, aggregates_by_name)
    end

    def read_model_options_skip_reason(extra)
      "declares #{extra.map(&:to_s).sort.join(', ')} — out of scope for this generator: cursor/" \
        "consistency/inspection are real " \
        "capabilities Ports::Query::InMemory/Ports::Query::Ordering/TenantScope implement that this generator " \
        "does not port (this file's own header has the full argument, the same boundary queries.rb already " \
        "draws for a declared AGGREGATE query); freshness/use_index are never disqualifying on their own — " \
        "neither is read by the in-memory interpreter path this kernel matches"
    end

    # `ReadModel#filtered_head_name`, ported directly — trusts the
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

      # `declared_authorization_skip_reason` — reused from `queries.rb`
      # wholesale (it's already generic over "some aggregate, some
      # authorization hash," nothing query-specific in it), aimed at the
      # ELIGIBLE HEAD's own aggregate — `read_model_filtered_head_as`
      # above already treats a real `authorization.tenant` as one of the
      # things that makes a head eligible in the first place, the same
      # way Ruby's own `filtered_head_name` does.
      auth_reason = declared_authorization_skip_reason(read_model[:authorization], aggregate, value_objects_by_name)
      return auth_reason if auth_reason

      # `declared_order_by_skip_reason`/`declared_limit_skip_reason` — moved
      # to `queries.rb` (2026-08-11), not defined here: a declared AGGREGATE
      # query needed the IDENTICAL field-kind/literal-shape checks for its
      # own `order_by`/`limit` (that file's own header has the argument),
      # and both are already generic over "some aggregate, some order_by/
      # limit hash" — nothing in either check is read-model-specific, so
      # the only change reuse asked of them was the name (module_function
      # already put them within reach of every file in this module).
      order_reason = declared_order_by_skip_reason(read_model[:order_by], aggregate, value_objects_by_name)
      return order_reason if order_reason

      offset_reason = declared_offset_skip_reason(read_model[:offset])
      return offset_reason if offset_reason

      declared_limit_skip_reason(read_model[:limit])
    end

    # `count`/`median`'s own eligibility, checked LAST — after the
    # ordinary where/order_by/limit/offset content check already passed
    # for the eligible head, since both real corpus declarations
    # (`DisputedPaymentCount`/`DisputedPaymentMedian`) reuse that SAME
    # `where(status: "disputed")` machinery `ComplianceDashboard` already
    # generates unchanged — `count`/`median` are reductions of the
    # already-filtered row set, not a separate shape needing its own root/
    # head eligibility check the way `group_by`'s narrower rootless-only
    # slice did. `seal_aggregation` (Ruby, build time) already guarantees
    # exactly one many-side head, and mutual exclusion with `group_by`/
    # with each other, by the time this ever runs — this doesn't re-derive
    # either. `count` needs no further check at all (a bare row count has
    # nothing to validate); `median`'s own FIELD is the one genuinely new
    # thing to confirm: does it name a real attribute on the eligible
    # many-side head's own aggregate, and is it numeric (`Runtime::
    # ReadModelInterpreter#aggregation_target`'s own check, ported here via
    # `query_field_kind` — the SAME "comparable reduces to a JSON number"
    # rule the generated `kernel::read_model::median` function's own
    # runtime reduction relies on, reused rather than re-derived).
    def aggregation_skip_reason(read_model, aggregates_by_name)
      return nil unless read_model[:median_field]

      target = read_model[:aggregate_heads].find { |head| head[:many] }
      aggregate = aggregates_by_name[target[:aggregate]]
      value_objects_by_name = aggregate[:value_objects].to_h { |vo| [vo[:name], vo] }

      field = read_model[:median_field].to_s
      kind = query_field_kind(aggregate, field, value_objects_by_name)
      return "median names #{field.inspect}, but #{target[:aggregate]} declares no such attribute — not generated yet" if kind == :unknown
      return "median names #{field.inspect} on #{target[:aggregate]}, which is not numeric — median needs a numeric " \
             "field (a bare number, or a value object carrying one) — not generated yet" unless kind == :number

      nil
    end

    # A REAL, NEWLY-CONFIRMED BOUNDARY, distinct from every other gap
    # this file already names: an `include` naming an ENTITY, not an
    # aggregate. `aggregates_by_name` — this whole file's own head/join
    # machinery, `AggregateScan`/`filter_entries` included — has no
    # concept of scanning an entity's own records at all; entities live
    # nested inside their owning aggregate's storage, not their own
    # top-level table, so "fetch every Member" isn't a query this
    # generator's `kernel/repository.rs` primitives can even express,
    # let alone FK-match against a sibling head the way an ordinary
    # aggregate head already does. The one real corpus site is the
    # self-hosted grammar's own `Bluebook::WholeBluebook` (`include
    # Member` — S17/ADR 0026 retired Member's own root aggregate in
    # favor of a genuine nested entity under ValueObject, and this
    # `include` was never updated to match). Confirmed this has no
    # working path on EITHER side today, not merely an unported Rust
    # gap: no spec anywhere dispatches or queries `WholeBluebook` for
    # real (grep spec/ finds exactly one comment mentioning it, in
    # self_use_spec.rb, about the read model's existence as a design
    # rationale — never its own execution). A genuinely new subsystem
    # this generator has no code path for at all, the same class of
    # "missing subsystem, not a parity bug" `group_by`'s own history
    # (above) already drew a line around before this file supported it
    # for real — worth its own dedicated design (does an entity-typed
    # head mean "every element across every instance of the owning
    # aggregate," or something narrower scoped to the reference root?
    # ReadModelInterpreter's own Ruby answer would need reading closely
    # before generating anything), not attempted here.
    def read_model_head_skip_reason(head, aggregates_by_name, unsupported_names)
      target = aggregates_by_name[head[:aggregate]]
      return "includes #{head[:aggregate]}, which this domain never declares" unless target
      return "includes #{head[:aggregate]}, which this generator couldn't itself generate " \
             "(unsupported attribute type — see this domain's own aggregate-level manifest entry)" if unsupported_names.include?(head[:aggregate])

      nil
    end

    # `group_by`'s own eligibility — deliberately narrow, the ONE real
    # shape the corpus declares (`Banking::AccountsByKind`): a single
    # ROOTLESS head (`ReadModelInterpreter#group_by_target`'s own
    # `target = model.aggregate_heads.find { |head| head[:many] }` only
    # ever needs to consider one candidate when there's only one head at
    # all), group_by alone — no where/order/limit/offset/count/median/
    # authorize declared alongside it, each its own genuinely different
    # shape this generator doesn't ALSO attempt to combine with grouping
    # in the same pass. `seal_group_by`'s own build-time refusal (Ruby)
    # already guarantees at most one many-side head when group_by is
    # declared at all — this doesn't re-derive that, only refuses
    # generating anything this narrower slice doesn't cover yet.
    def group_by_skip_reason(read_model, aggregates_by_name, unsupported_names)
      heads = read_model[:aggregate_heads]
      return "declares group_by across #{heads.size} aggregate heads — not generated yet (only a single, rootless head is)" if heads.size != 1
      return "declares group_by on a NON-rootless read model (reference_to #{read_model[:reference_target]}) — not generated yet" unless read_model[:reference_target].nil?
      return "declares group_by alongside count/median — not generated yet" if read_model[:count] || read_model[:median_field]
      return "declares group_by alongside where/order_by/limit/offset — not generated yet" if Array(read_model[:wheres]).any? || read_model[:order_by] || read_model[:limit] || read_model[:offset]
      return "declares group_by with an authorize policy — not generated yet" if read_model[:authorization]

      head = heads.first
      reason = read_model_head_skip_reason(head, aggregates_by_name, unsupported_names)
      return reason if reason

      aggregate = aggregates_by_name[head[:aggregate]]
      lifecycle_field = aggregate[:lifecycle] && aggregate[:lifecycle][:field].to_s
      Array(read_model[:group_by]).each do |row|
        field_s = row[:field].to_s
        next if aggregate[:attributes].any? { |a| a[:name].to_s == field_s }
        next if field_s == lifecycle_field

        return "group_by names #{field_s.inspect}, but #{aggregate[:name]} declares no such attribute — not generated yet"
      end

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
    # `Attribute` does. Every reference attribute is included
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
    # `kernel/read_model.rs`'s own `ReadModelOrderBy`. `null_semantics` is
    # a separate, sibling top-level read-model key, same as it is for a
    # declared AGGREGATE query — `queries.rb`'s own `null_semantics_
    # variant` reused directly rather than duplicated (`ReadModelOrderBy`
    # is `query_ordering::OrderBy` itself, an alias — the compiled `nulls:`
    # field means the identical thing either spelling is read through).
    def emit_read_model_order_by(order_by, null_semantics = nil)
      descending = order_by[:direction].to_s == "desc" ? "true" : "false"
      "crate::kernel::read_model::ReadModelOrderBy { field: #{order_by[:field].to_s.inspect}, descending: #{descending}, " \
        "nulls: #{null_semantics_variant(null_semantics)} }"
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

    # `offset`'s own compiled form — `crate::kernel::read_model::
    # ReadModelOffset` is `pub type ReadModelOffset = query_ordering::
    # Offset` (itself `= query_ordering::Limit` — see that module's own
    # header), so this reuses `emit_read_model_limit`'s own computation
    # and swaps only the spelled type name, the identical move `queries.rb`'s
    # own `emit_query_offset` makes for a declared AGGREGATE query's offset.
    def emit_read_model_offset(offset) = emit_read_model_limit(offset).sub("read_model::ReadModelLimit::", "read_model::ReadModelOffset::")

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
      group_by_fields = Array(read_model[:group_by]).map { |row| row[:field].to_s }
      group_by_fn_name = group_by_fields.any? ? "group_by_#{read_model[:name].to_s.downcase}" : nil

      {
        verb: "#{domain_name}.#{read_model[:name]}",
        reference_name: read_model[:reference_name] ? read_model[:reference_name].to_s : nil,
        heads: heads,
        filtered_head: eligible_as&.to_s,
        conditions: eligible_as ? query_conditions_with_authorization(read_model) : [],
        order_by: eligible_as && read_model[:order_by] ? emit_read_model_order_by(read_model[:order_by], read_model[:null_semantics]) : nil,
        offset: eligible_as && read_model[:offset] ? emit_read_model_offset(read_model[:offset]) : nil,
        limit: eligible_as && read_model[:limit] ? emit_read_model_limit(read_model[:limit]) : nil,
        authorization: eligible_as ? emit_query_authorization(read_model[:name], read_model[:authorization]) : nil,
        group_by_fn: group_by_fn_name,
        group_by_fn_body: group_by_fn_name ? emit_group_by_transform(group_by_fn_name, aggregates_by_name[read_model[:aggregate_heads].first[:aggregate]], group_by_fields) : nil,
        count: !!read_model[:count],
        median_field: read_model[:median_field] ? read_model[:median_field].to_s : nil,
      }
    end

    # The generated function `ReadModelDef.group_by` names by value
    # (`fn(Vec<(String, Json)>) -> Json`) — `kernel/read_model.rs`'s own
    # header on why this can't be one more data-driven field the way
    # `offset`/`order_by` already are: which field is a single-attribute
    # value object is a TYPE-LEVEL fact this generator has at Ruby-codegen
    # time but the kernel's own generic `run` function never does once
    # it's holding already-serialized `Json`.
    #
    # Three real jobs, in order: (1) `repository::row_json`-equivalent —
    # add `id` back (Rust's own generated `to_json()` never carries it,
    # unlike a live Ruby record's `to_h`); (2) keep ONLY this aggregate's
    # own real declared attributes (+ lifecycle, + id) — EXCLUDING any
    # synthetic field a DIFFERENT Phase 10 capability may have added to
    # the record's own JSON shape (`corrects`'s own `emitted_*` flags,
    # ADR 0049 — real Rust-only bookkeeping with no Ruby analog, which
    # `Instance#to_h` never carries either); (3) recursively unwrap every
    # single-attribute value object along the way (`unwrap_json_expr`),
    # matching `Value.materialize_unwrapped` exactly. `kernel::read_model
    # ::nest` (hand-written once, purely structural — no type knowledge
    # needed for grouping/stripping itself) does the actual nesting.
    def emit_group_by_transform(fn_name, aggregate, group_by_fields)
      value_objects_by_name = aggregate[:value_objects].to_h { |vo| [vo[:name].to_s, vo] }
      lifecycle_field = aggregate[:lifecycle] && aggregate[:lifecycle][:field].to_s
      kept_keys = aggregate[:attributes].map { |a| a[:name].to_s } + ["id"] + (lifecycle_field ? [lifecycle_field] : [])
      keep_cond = kept_keys.map { |k| "k == #{k.inspect}" }.join(" || ")

      arms = aggregate[:attributes].map do |a|
        unwrapped = unwrap_json_expr("v", a[:type].to_s, a[:list], aggregate, value_objects_by_name)
        "#{a[:name].to_s.inspect} => #{unwrapped},"
      end.join("\n                    ")

      fields_literal = "&[#{group_by_fields.map(&:inspect).join(', ')}]"

      <<~RUST.rstrip
        pub fn #{fn_name}(rows: Vec<(String, crate::kernel::Json)>) -> crate::kernel::Json {
            let unwrapped: Vec<crate::kernel::Json> = rows
                .into_iter()
                .map(|(id, record)| {
                    let wrapped = crate::kernel::repository::row_json(id, record);
                    match wrapped {
                        crate::kernel::Json::Object(fields) => crate::kernel::Json::Object(
                            fields
                                .into_iter()
                                .filter(|(k, _)| #{keep_cond})
                                .map(|(k, v)| {
                                    let new_v = match k.as_str() {
                    #{arms}
                                        _ => v,
                                    };
                                    (k, new_v)
                                })
                                .collect(),
                        ),
                        other => other,
                    }
                })
                .collect();
            crate::kernel::read_model::nest(unwrapped, #{fields_literal})
        }
      RUST
    end

    # `Value.materialize_unwrapped`, ported directly — a single-attribute
    # value object (`AccountKind{name: "current"}`) unwraps to its own
    # bare field (`"current"`); a multi-attribute one, or an ENTITY
    # (`Account.ledger`'s own `LedgerEntry`, which never appears in
    # `value_objects_by_name` at all — entities and value objects are
    # separate IR constructs), keeps its own object shape but recurses
    # into EACH of its own declared fields the same way; a bare scalar
    # (String/Integer/Float/Reference) or an unrecognized composite type
    # passes through unchanged. `list:` wraps the same logic in an
    # `Array` map — a list of value objects and a list of entities are
    # unwrapped identically either way, matching Ruby's own
    # `when Array then value.map { |item| materialize_unwrapped(item) }`,
    # which never special-cases what the array HOLDS.
    def unwrap_json_expr(expr, type_name, list, aggregate, value_objects_by_name)
      if list
        inner = unwrap_json_expr("item", type_name, false, aggregate, value_objects_by_name)
        return "match #{expr} { crate::kernel::Json::Array(items) => crate::kernel::Json::Array(items.into_iter().map(|item| #{inner}).collect()), other => other }"
      end

      vo = value_objects_by_name[type_name]
      entity = (aggregate[:entities] || []).find { |e| e[:name].to_s == type_name.to_s }
      fields_meta = vo ? vo[:attributes] : (entity ? entity[:attributes] : nil)
      return expr unless fields_meta

      if vo && fields_meta.size == 1
        field = fields_meta.first
        unwrapped = unwrap_json_expr("field_value", field[:type].to_s, field[:list], aggregate, value_objects_by_name)
        return "match #{expr} { crate::kernel::Json::Object(fields) => fields.into_iter().find(|(k, _)| k == #{field[:name].to_s.inspect}).map(|(_, field_value)| #{unwrapped}).unwrap_or(crate::kernel::Json::Null), other => other }"
      end

      inner_arms = fields_meta.map do |f|
        unwrapped = unwrap_json_expr("v", f[:type].to_s, f[:list], aggregate, value_objects_by_name)
        "#{f[:name].to_s.inspect} => #{unwrapped},"
      end.join(" ")
      "match #{expr} { crate::kernel::Json::Object(fields) => crate::kernel::Json::Object(fields.into_iter().map(|(k, v)| { let new_v = match k.as_str() { #{inner_arms} _ => v }; (k, new_v) }).collect()), other => other }"
    end

    def emit_read_model_def(read_model_def)
      heads = read_model_def[:heads].map { |head| "        #{head}," }.join("\n")
      conditions = read_model_def[:conditions].map { |c| "        #{emit_query_condition(c)}" }.join("\n")
      filtered_head = read_model_def[:filtered_head] ? "Some(#{read_model_def[:filtered_head].inspect})" : "None"
      order_by = read_model_def[:order_by] ? "Some(#{read_model_def[:order_by]})" : "None"
      offset = read_model_def[:offset] ? "Some(#{read_model_def[:offset]})" : "None"
      limit = read_model_def[:limit] ? "Some(#{read_model_def[:limit]})" : "None"
      authorization = read_model_def[:authorization] ? "Some(#{read_model_def[:authorization]})" : "None"
      reference_name = read_model_def[:reference_name] ? "Some(#{read_model_def[:reference_name].inspect})" : "None"
      group_by = read_model_def[:group_by_fn] ? "Some(#{read_model_def[:group_by_fn]})" : "None"
      count = read_model_def[:count] ? "true" : "false"
      median_field = read_model_def[:median_field] ? "Some(#{read_model_def[:median_field].inspect})" : "None"

      <<~RUST.rstrip
        crate::kernel::read_model::ReadModelDef {
            verb: #{read_model_def[:verb].inspect},
            reference_name: #{reference_name},
            heads: &[
        #{heads}
            ],
            filtered_head: #{filtered_head},
            conditions: &[
        #{conditions}
            ],
            order_by: #{order_by},
            offset: #{offset},
            limit: #{limit},
            authorization: #{authorization},
            group_by: #{group_by},
            count: #{count},
            median_field: #{median_field},
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
          reference_name: Some("tmpl_reference_name"),
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
          order_by: Some(crate::kernel::read_model::ReadModelOrderBy { field: "tmpl_order_field", descending: true, nulls: crate::kernel::query_ordering::NullsMode::Last }),
          offset: Some(crate::kernel::read_model::ReadModelOffset::Literal(1)),
          limit: Some(crate::kernel::read_model::ReadModelLimit::Literal(5)),
          authorization: Some(crate::kernel::named_query::TenantAuth { query_name: "tmpl_query_name", tenant_field: "tmpl_tenant_field" }),
          group_by: None,
          count: false,
          median_field: None,
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
