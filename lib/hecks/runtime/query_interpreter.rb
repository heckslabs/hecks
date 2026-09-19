require_relative "../naming"
require_relative "../ports/query"
require_relative "../ports/query/ordering"
require_relative "../query_specification/field_path"
require_relative "../query_specification/common/comparison"
require_relative "errors"
require_relative "reference_hop"
require_relative "refusal_wording"
require_relative "tenant_scope"
require_relative "value"

module Hecks
  module Runtime
    # Answers one declared aggregate or entity query against a
    # repository: prefers a native adapter hook (Ports::Query.execute)
    # when the store can answer directly, falling back to interpreting
    # wheres/order_by/limit/offset over every loaded record itself.
    # #reference_call/#reference_interpret are a separate, deliberately
    # naive re-implementation of the same evaluation, used only as the
    # fuzzer's oracle to catch divergence between adapters and this
    # interpreter's own native path.
    class QueryInterpreter
      attr_reader :registry

      # @param registry [Runtime::Registry] the booted registry this interpreter reads
      #   repositories from
      def initialize(registry)
        @registry = registry
      end

      # Answers a declared aggregate, entity, or sub-list query.
      #
      # @param domain [String] the domain the aggregate belongs to
      # @param aggregate [Bluebook::Aggregate] the aggregate to query
      # @param query_name [String] the declared query's name, or a dotted `"Entity.Query"`
      #   name for an entity/sub-list query
      # @param args [Hash] the query's arguments
      # @return [Array<Hash>] the matching rows, each frozen, `id` merged in last
      # @raise [Runtime::UnknownVerb] if `query_name` (or, for a dotted name, the entity or
      #   its list attribute) is not declared
      # @raise [Runtime::TypeMismatch] if an offered argument does not coerce to its declared
      #   type
      # @raise [Runtime::Unauthorized] if the query declares `authorize policy, tenant:
      #   :field` and `args` omits that field
      def call(domain, aggregate, query_name, args)
        return entity_rows(domain, aggregate, query_name, args) if query_name.include?(".")

        declared = declared_query(aggregate, query_name)
        args = normalize_args(aggregate, declared, args)
        declared = TenantScope.apply(declared, args)
        # After TenantScope, so its synthetic clause is already present
        # in `.wheres` and rides through as an ordinary local clause on
        # the outer query. It does not reach the hop's own inner
        # sub-query against the target aggregate — a hop's target may
        # not even declare the same tenant boundary, and propagating one
        # aggregate's tenant scope onto an unrelated aggregate's own
        # query is a real design question of its own, not answered here.
        declared = ReferenceHop.apply(declared, args, registry: @registry, domain: domain, aggregate: aggregate)

        repository = @registry.repository(domain, aggregate)
        # `registry:` is threaded through so a `none_in_state` where-clause
        # can look its target aggregate up — see
        # QuerySpecification::Common::Comparison#none_in_state? for the
        # comparator itself, and for why an ordinary aggregate-level
        # Memory query needs the registry passed explicitly rather than
        # closing over an instance variable.
        if (native = Ports::Query.execute(repository, declared, args,
                                          context: { domain: domain, aggregate: aggregate, registry: @registry }))
          records = native
          # `record.state.merge(id: record.id)` — id last, not first. See
          # Instance#to_h's own comment: an aggregate free to declare its
          # own attribute literally named `id` has that attribute's own
          # wrapped value sitting in `record.state[:id]` already; merging
          # it over a `{id:}.merge(state)` would let it silently
          # clobber the correct bare identity this row is supposed to
          # carry.
          # A query row is an answer, not a handle. Mutating one edits
          # nobody's state and silently disagrees with the store.
          return Freezer.deep(records.map { |record| record.state.merge(id: record.id) })
        end

        Freezer.deep(interpret(repository.all, declared, args, domain: domain))
      end

      # The reference answer — this interpreter's own evaluation, never an
      # adapter's native hook. The fuzzer's query oracle replays every
      # generated ask through both paths and treats a difference as a
      # finding: the differential gate the retired cross-runtime harness
      # should always have been, aimed where the divergence actually
      # lives — between the engines inside this one runtime.
      #
      # A hop clause is answered here by its own, deliberately naive
      # walk (reference_where_holds?) — never Runtime::ReferenceHop's
      # partition/fold/in-clause. Sharing that algorithm would have made
      # this oracle blind to exactly the code the hop feature adds: every
      # phase of a shared fold would still get diffed against the native
      # adapters, but the fold itself — the empty candidate set, a
      # duplicate id, a dangling reference, a chain's inside-out
      # resolution order — would only ever be compared against itself.
      #
      # @param domain [String] the domain the aggregate belongs to
      # @param aggregate [Bluebook::Aggregate] the aggregate to query
      # @param query_name [String] the declared query's name, or a dotted `"Entity.Query"`
      #   name for an entity/sub-list query
      # @param args [Hash] the query's arguments
      # @return [Array<Hash>] the matching rows, `id` merged in last; not frozen (an oracle
      #   answer, never handed to a caller)
      # @raise [Runtime::UnknownVerb] if `query_name` (or, for a dotted name, the entity or
      #   its list attribute) is not declared
      # @raise [Runtime::TypeMismatch] if an offered argument does not coerce to its declared
      #   type
      # @raise [Runtime::Unauthorized] if the query declares `authorize policy, tenant:
      #   :field` and `args` omits that field
      def reference_call(domain, aggregate, query_name, args)
        return entity_rows(domain, aggregate, query_name, args) if query_name.include?(".")

        declared = declared_query(aggregate, query_name)
        args = normalize_args(aggregate, declared, args)
        declared = TenantScope.apply(declared, args)
        reference_interpret(@registry.repository(domain, aggregate).all, declared, args,
                            domain: domain, shape: aggregate)
      end

      private

      def declared_query(aggregate, query_name)
        aggregate.query(query_name) ||
          raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "no_query",
                                                        aggregate: aggregate.hecks_name, query: query_name))
      end

      def interpret(records, declared, args, domain: nil)
        matched = records.select { |r| declared.wheres.all? { |w| where_holds?(w, r, args, domain: domain) } }
        ordered = ordered(matched, declared.order_by, declared.null_semantics)
        # **Offset first, then limit** — the order SQL means by `LIMIT n
        # OFFSET m`, and the order Ports::Query::InMemory#execute already
        # applies (see that file's own comment). Reading `declared.offset`
        # here matters: without it, offset would silently vanish for any
        # query answered here, not just come out reversed.
        skipped = declared.offset ? ordered.drop(resolve_query_value(declared.offset.value, args).to_i) : ordered
        capped  = declared.limit ? skipped.first(resolve_query_value(declared.limit.value, args).to_i) : skipped

        # id last — see the native-path comment above; same clobbering
        # risk for the in-memory reference interpreter's own rows.
        capped.map { |r| r.state.merge(id: r.id) }
      end

      # `interpret`'s own twin, for reference_call alone — same
      # select/order/limit shape, but a clause that hops through a
      # reference is answered by reference_where_holds? instead of the
      # plain FieldPath.dig(record, field) `where_holds?` uses (which
      # has no concept of a reference at all — it would just read the
      # raw id straight off the record and compare that).
      def reference_interpret(records, declared, args, domain:, shape:)
        matched = records.select do |r|
          declared.wheres.all? do |w|
            reference_where_holds?(w, r, args, domain: domain, shape: shape)
          end
        end
        ordered = ordered(matched, declared.order_by, declared.null_semantics)
        # **Offset first, then limit** — same fix, same reasoning, as
        # #interpret's own rows above.
        skipped = declared.offset ? ordered.drop(resolve_query_value(declared.offset.value, args).to_i) : ordered
        capped  = declared.limit ? skipped.first(resolve_query_value(declared.limit.value, args).to_i) : skipped

        # id last — same reasoning, same fix, as interpret's own rows.
        capped.map { |r| r.state.merge(id: r.id) }
      end

      # **The naive reading of a hop**: not a fold, not an id set — for
      # each candidate row, walk the reference by hand and dig the
      # field out of whatever it actually points at. A nil reference,
      # or one that resolves to nothing (a dangling id), makes the
      # whole clause false outright, whatever the comparator — "points
      # at a client that is not active" is false for a proposal with no
      # client at all, the same way it is false for one whose client
      # really is active; falling through to holds?(clause, nil, args)
      # instead would answer `ne` wrong (nil != "active" is true).
      def reference_where_holds?(clause, record, args, domain:, shape:)
        step = QuerySpecification::HopPath.next_hop(clause.field, shape.attributes)
        return where_holds?(clause, record, args) unless step

        hop, rest = step
        inner = QuerySpecification::Common::WhereClause.new(field: rest, op: clause.op, value: clause.value)
        held = record[hop.attribute.name]
        reference_ids = hop.attribute.list? ? Array(held) : [held]

        reference_ids.compact.any? do |reference_id|
          target_record = @registry.repository(domain, hop.target).find(reference_id)
          next false unless target_record

          reference_where_holds?(inner, target_record, args, domain: domain, shape: hop.target)
        end
      end

      def entity_rows(domain, aggregate, dotted, args)
        entity_name, query_name = Naming.split_dotted(dotted)
        entity, declared, list_attr = resolve_entity_query(aggregate, entity_name, query_name)
        declared = TenantScope.apply(declared, args)

        parent_key = Naming.reference_key(aggregate.hecks_name)
        rows = @registry.repository(domain, aggregate).all.flat_map do |record|
          Array(record[list_attr.name])
            .select { |el| declared.wheres.all? { |w| element_where_holds?(w, el, args) } }
            .map    { |el| { parent_key => record.id }.merge(el) }
        end

        ordered = ordered_elements(rows, declared.order_by, declared.null_semantics,
                                   parent_key, entity.identity_heads)
        # **Offset first, then limit** — same fix, same reasoning, as
        # #interpret's own rows above. `entity_rows` is the only engine
        # for entity/sub-list queries, so a declared offset here silently
        # vanished for every entity query, not merely one path among
        # several.
        skipped = declared.offset ? ordered.drop(resolve_query_value(declared.offset.value, args).to_i) : ordered
        declared.limit ? skipped.first(resolve_query_value(declared.limit.value, args).to_i) : skipped
      end

      # The three declarations `entity_rows` needs before it can read a
      # single record — the entity itself, its declared query, and the
      # list attribute that holds it on the aggregate. Extracted from
      # `entity_rows` (pure extraction, same lookups, same order, same
      # UnknownVerb refusals) purely to separate "which declarations does
      # this dotted name resolve to" from the row-computation that follows.
      def resolve_entity_query(aggregate, entity_name, query_name)
        entity = aggregate.entities.find { |piece| piece.hecks_name == entity_name } ||
                 raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "entity_unknown",
                                                               aggregate: aggregate.hecks_name, entity: entity_name))
        declared = entity.query(query_name) ||
                   raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "entity_query_missing",
                                                                 entity: entity_name, query: query_name))
        list_attr = aggregate.attributes.find { |a| a.list? && a.type.to_s == entity_name } ||
                    raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "entity_holds_no_list",
                                                                  aggregate: aggregate.hecks_name, entity: entity_name))
        [entity, declared, list_attr]
      end

      # FieldPath.dig, not a raw `element[clause.field.to_sym]` — a dotted
      # `where` (`where "price.cents" < 100`) needs the same segment-by-
      # segment walk every other query path already gets. Reading the whole
      # dotted string as one key always missed — `element[:"price.cents"]`
      # is never a real key — so a dotted where on an entity query
      # silently matched nothing, on the only engine entity queries have.
      def element_where_holds?(clause, element, args)
        holds?(clause, QuerySpecification::FieldPath.dig(element, clause.field), args)
      end

      # A row's own key. A sub-list row is a hydrated entity element (symbol-keyed
      # since every adapter decodes through `Ports::Persistence::StateCodec` and
      # `EntityListCoercion#hydrate_entity_list` symbolizes each element — PR A4
      # removed the string-spelling fallback that coped with the old per-adapter
      # shapes). It rides `comparable` for the same reason a where-clause does : an
      # identity is a value object, and `to_s` on one is an object address — a sort key
      # that differs run to run, which is worse than the store order it replaced.
      def cell(row, key) = row[key.to_sym]

      # A sub-list row is identified by its parent and then its own key : two
      # entities under different parents can share a sequence, so the parent has
      # to lead or the tie is not broken at all.
      #
      # Every key the piece is known by, in declaration order, for the same
      # reason the parent leads: a part that ties is a part that breaks no tie.
      # This took `identified_by`, which is the single head and is nil the
      # moment an identity has two parts — and `cell(row, nil)` calls
      # `nil.to_sym`, so a query against a composite piece did not sort wrongly,
      # it raised. A piece known by one key sorts exactly as it did.
      def ordered_elements(rows, order_by, null_semantics, parent_key, entity_keys)
        field = order_by&.field
        Ports::Query::Ordering.apply(
          rows, order_by, null_semantics,
          identity: lambda { |row|
            [row[parent_key].to_s, *Array(entity_keys).map { |key| comparable(cell(row, key)) }]
          }
        ) { |row| comparable(QuerySpecification::FieldPath.dig(row, field)) }
      end

      def where_holds?(clause, record, args, domain: nil)
        holds?(clause, QuerySpecification::FieldPath.dig(record, clause.field), args, record: record, domain: domain)
      end

      # The comparator table itself lives in
      # QuerySpecification::Common::Comparison, shared rather than copied
      # separately by this method and Ports::Query::InMemory#holds? — a
      # copy each is what would let `none_in_state` reach only one of
      # them, and `comparable` disagree about value objects with two
      # numeric members. What stays here is how a value is reached for
      # this path: the registry is instance state rather than an argument.
      def holds?(clause, held, args, record: nil, domain: nil)
        QuerySpecification::Common::Comparison.holds?(
          clause.op, comparable(held), comparable(resolve_query_value(clause.value, args)), registry: @registry
        )
      end

      def resolve_query_value(value, args)
        value.is_a?(Symbol) ? args[value] : value
      end

      # `boundary: false` always (C3.8 — a query's declared argument types
      # name the argument for callers and generators, never a runtime
      # shape checked here). A null required value-object-typed query
      # argument, though, is not a runtime-shape question at all: C3.7
      # says a named query's declared value-object arguments are checked
      # the same way a command argument's own is, so a `nil` offered for
      # a non-optional value-object-typed query attribute
      # (Governance::RoleAssignment.AssignmentsForActor's `actor_id`, say)
      # has to refuse — passing it through unchecked would let it through
      # as a silent, unfiltered query instead, a real Ruby/Rust
      # divergence the fuzzer caught (QualityControl BUG#2).
      #
      # `checked_vo?` true is handled by `null_vo_argument!` directly,
      # never by routing through `Value.for_attribute(argument: true)`
      # into the shared `Value::Coercion#nil_argument` the command door
      # (`Interpreting#coerce_declared_arguments`) still uses — that
      # method builds a null value object from zero fields, which
      # succeeds (silently absorbing the null via the type's own field
      # defaults) whenever every field happens to have one
      # (`Lease.Expired`'s `now`, a `LeaseInstant` with a `default: 0`
      # field; `Account.Overdrawn`/`HighBalance`/`StrictlyAbove`/
      # `AtMost`'s `floor`/`cap`, a two-defaulted-field `Money`) and only
      # refuses when a field has none (`Order.CostingLessThan`'s
      # `ceiling`, a defaultless `Price`) — a real query-side divergence
      # from Rust, which always refuses `TypeMismatch` on an explicit
      # null argument regardless of any default (QualityControl BUG#36).
      # `null_vo_argument!` instead treats an explicit null exactly the
      # way `Value.fields_for` already treats any other wrong-shaped
      # (non-Hash, non-Value) value offered for that same attribute — a
      # single-field value object auto-wraps into `{field: nil}` (whose
      # own `nil` is a present key, so `Value.build`'s `apply_defaults`
      # never fills it, and `check_required_fields` refuses it exactly
      # as any other missing required field would); a multi-field value
      # object refuses immediately with the same `value_object_shape`
      # wording an ordinary wrong-shaped scalar already gets. Command
      # arguments are deliberately untouched — this is a query-only
      # door; `nil_argument`'s own default-absorbing fallback still
      # governs a null command argument exactly as it always has.
      #
      # C3.8's own bare-scalar carve-out stays intact: `checked_vo?` is
      # only true for a value-object-typed attribute, so a bare
      # `String`/`Integer` query argument offered nil still passes
      # through exactly as it always did.
      def normalize_args(aggregate, declared, args)
        declared.attributes.each_with_object(args.dup) do |attribute, normalized|
          next unless normalized.key?(attribute.name)

          value = normalized[attribute.name]
          normalized[attribute.name] = if checked_vo?(aggregate, attribute, value)
                                         null_vo_argument!(aggregate, attribute)
                                       else
                                         Value.for_attribute(aggregate, attribute, value, boundary: false)
                                       end
        end
      end

      def checked_vo?(aggregate, attribute, value)
        return false unless value.nil?
        return false if attribute.optional? || attribute.list? || attribute.reference?
        return false unless aggregate.respond_to?(:value_object)

        !Value.value_object_for(aggregate, attribute.type).nil?
      end

      # Only ever reached when `checked_vo?` has already confirmed the
      # attribute's type resolves to a real value object — see its own
      # comment above for why this refuses unconditionally, never
      # absorbing the null via the type's own field defaults.
      def null_vo_argument!(aggregate, attribute)
        value_object = Value.value_object_for(aggregate, attribute.type)
        Value.build(value_object, Value.fields_for(value_object, attribute.name, nil), aggregate)
      end

      def comparable(value) = QuerySpecification::Common::Comparison.comparable(value)

      # FieldPath.dig, not a raw `record[field]` — `record` is an Instance
      # here, and a dotted order_by (`order_by "price.cents"`) is a
      # single symbol key (`:"price.cents"`) that never matches anything
      # `Instance#[]` actually holds, so a dotted order_by silently sorted
      # by all-nil (the identity tier alone deciding every tie) on this,
      # the reference/no-native-hook engine — the same bug already fixed
      # for `where` (see `where_holds?` above) and for entity rows (see
      # `ordered_elements` below), just not yet for this, the aggregate-
      # level order_by.
      def ordered(records, order_by, null_semantics = nil)
        field = order_by&.field
        Ports::Query::Ordering.apply(records, order_by, null_semantics,
                                     identity: ->(record) { record.id.to_s }) do |record|
          comparable(QuerySpecification::FieldPath.dig(record, field))
        end
      end
    end
  end
end
