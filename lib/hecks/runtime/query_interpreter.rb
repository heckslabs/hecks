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
    class QueryInterpreter
      attr_reader :registry

      def initialize(registry)
        @registry = registry
      end

      def call(domain, aggregate, query_name, args)
        return entity_rows(domain, aggregate, query_name, args) if query_name.include?(".")

        declared = declared_query(aggregate, query_name)
        args = normalize_args(aggregate, declared, args)
        declared = TenantScope.apply(declared, args)
        # AFTER TenantScope, so its synthetic clause is already present
        # in `.wheres` and rides through as an ordinary LOCAL clause on
        # the OUTER query. It does not reach the hop's own inner
        # sub-query against the TARGET aggregate — a hop's target may
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
          # `record.state.merge(id: record.id)` — id LAST, not first. See
          # Instance#to_h's own comment: an aggregate free to declare its
          # own attribute literally named `id` has that attribute's own
          # wrapped value sitting in `record.state[:id]` already; merging
          # it OVER a `{id:}.merge(state)` used to let it silently
          # clobber the correct bare identity this row is supposed to
          # carry.
          # A QUERY ROW IS AN ANSWER, NOT A HANDLE. Mutating one edits
          # nobody's state and silently disagrees with the store.
          return Freezer.deep(records.map { |record| record.state.merge(id: record.id) })
        end

        Freezer.deep(interpret(repository.all, declared, args, domain: domain))
      end

      # The REFERENCE answer — this interpreter's own evaluation, never an
      # adapter's native hook. The fuzzer's query oracle replays every
      # generated ask through both paths and treats a difference as a
      # finding: the differential gate the retired cross-runtime harness
      # should always have been, aimed where the divergence actually
      # lives — between the engines inside this one runtime.
      #
      # A hop clause is answered here by its OWN, deliberately naive
      # walk (reference_where_holds?) — never Runtime::ReferenceHop's
      # partition/fold/IN-clause. Sharing that algorithm would have made
      # this oracle blind to exactly the code the hop feature adds: every
      # PHASE of a shared fold would still get diffed against the native
      # adapters, but the fold itself — the empty candidate set, a
      # duplicate id, a dangling reference, a chain's inside-out
      # resolution order — would only ever be compared against itself.
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
          raise(UnknownVerb, RefusalWording.render("UnknownVerb", "no_query",
                                                   aggregate: aggregate.hecks_name, query: query_name.inspect))
      end

      def interpret(records, declared, args, domain: nil)
        matched = records.select { |r| declared.wheres.all? { |w| where_holds?(w, r, args, domain: domain) } }
        ordered = ordered(matched, declared.order_by, declared.null_semantics)
        # OFFSET FIRST, THEN LIMIT — the order SQL means by `LIMIT n
        # OFFSET m`, and the order Ports::Query::InMemory#execute already
        # applies (see that file's own comment). This interpreter used to
        # never read declared.offset at all — offset silently vanished for
        # any query answered here, not just come out reversed.
        skipped = declared.offset ? ordered.drop(resolve_query_value(declared.offset.value, args).to_i) : ordered
        capped  = declared.limit ? skipped.first(resolve_query_value(declared.limit.value, args).to_i) : skipped

        # id LAST — see the native-path comment above; same clobbering
        # risk for the in-memory reference interpreter's own rows.
        capped.map { |r| r.state.merge(id: r.id) }
      end

      # `interpret`'s own twin, for reference_call alone — same
      # select/order/limit shape, but a clause that hops through a
      # reference is answered by reference_where_holds? instead of the
      # plain FieldPath.dig(record, field) `where_holds?` uses (which
      # has no concept of a reference at all — it would just read the
      # raw id straight off the record and compare THAT).
      def reference_interpret(records, declared, args, domain:, shape:)
        matched = records.select { |r|
          declared.wheres.all? { |w|
            reference_where_holds?(w, r, args, domain: domain, shape: shape)
          }
        }
        ordered = ordered(matched, declared.order_by, declared.null_semantics)
        # OFFSET FIRST, THEN LIMIT — same fix, same reasoning, as
        # #interpret's own rows above.
        skipped = declared.offset ? ordered.drop(resolve_query_value(declared.offset.value, args).to_i) : ordered
        capped  = declared.limit ? skipped.first(resolve_query_value(declared.limit.value, args).to_i) : skipped

        # id LAST — same reasoning, same fix, as interpret's own rows.
        capped.map { |r| r.state.merge(id: r.id) }
      end

      # THE NAIVE READING OF A HOP: not a fold, not an id set — for
      # each candidate row, walk the reference by hand and dig the
      # field out of whatever it actually points at. A nil reference,
      # or one that resolves to nothing (a dangling id), makes the
      # WHOLE clause false outright, whatever the comparator — "points
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
        entity = aggregate.entities.find { |piece| piece.hecks_name == entity_name } ||
                 raise(UnknownVerb, RefusalWording.render("UnknownVerb", "entity_unknown",
                                                          aggregate: aggregate.hecks_name, entity: entity_name.inspect))
        declared = entity.query(query_name) ||
                   raise(UnknownVerb, RefusalWording.render("UnknownVerb", "entity_query_missing",
                                                            entity: entity_name, query: query_name.inspect))
        declared = TenantScope.apply(declared, args)
        list_attr = aggregate.attributes.find { |a| a.list? && a.type.to_s == entity_name } ||
                    raise(UnknownVerb, RefusalWording.render("UnknownVerb", "entity_holds_no_list",
                                                             aggregate: aggregate.hecks_name, entity: entity_name))

        parent_key = Naming.reference_key(aggregate.hecks_name)
        rows = @registry.repository(domain, aggregate).all.flat_map do |record|
          Array(record[list_attr.name])
            .select { |el| declared.wheres.all? { |w| element_where_holds?(w, el, args) } }
            .map    { |el| { parent_key => record.id }.merge(el) }
        end

        ordered = ordered_elements(rows, declared.order_by, declared.null_semantics,
                                   parent_key, entity.identity_heads)
        # OFFSET FIRST, THEN LIMIT — same fix, same reasoning, as
        # #interpret's own rows above. `entity_rows` is the ONLY engine
        # for entity/sub-list queries, so a declared offset here silently
        # vanished for every entity query, not merely one path among
        # several.
        skipped = declared.offset ? ordered.drop(resolve_query_value(declared.offset.value, args).to_i) : ordered
        declared.limit ? skipped.first(resolve_query_value(declared.limit.value, args).to_i) : skipped
      end

      # FieldPath.dig, not a raw `element[clause.field.to_sym]` — an
      # entity sub-list row is a plain hash merged from stored state
      # (mixed string/symbol keys depending on adapter, per `#cell`'s own
      # comment below), and a dotted `where` (`where "price.cents" < 100`)
      # needs the same segment-by-segment walk every other query path
      # already gets. Reading only the symbol spelling of the WHOLE
      # dotted string as one key always missed — `element[:"price.cents"]`
      # is never a real key — so a dotted where on an entity query
      # silently matched nothing, on the only engine entity queries have.
      def element_where_holds?(clause, element, args)
        holds?(clause, QuerySpecification::FieldPath.dig(element, clause.field), args)
      end

      # A row's own key, however the store spells it. A sub-list row is a plain hash
      # merged from stored state, so its keys arrive as strings from one adapter and
      # symbols from another — and reading only one spelling gave every row the SAME
      # identity, which is a tie, which is the exact nondeterminism this tier exists
      # to remove. It rides `comparable` for the same reason a where-clause does : an
      # identity is a value object, and `to_s` on one is an OBJECT ADDRESS — a sort key
      # that differs run to run, which is worse than the store order it replaced.
      # `key?` decides which spelling answers, never `||` — a row whose
      # value is a genuinely-held `false` must not fall through to the
      # other spelling (usually absent) and land on `nil`.
      def cell(row, key)
        sym = key.to_sym
        row.key?(sym) ? row[sym] : row[key.to_s]
      end

      # A sub-list row is identified by its PARENT and then its own key : two
      # entities under different parents can share a sequence, so the parent has
      # to lead or the tie is not broken at all.
      #
      # EVERY KEY THE PIECE IS KNOWN BY, in declaration order, for the same
      # reason the parent leads: a part that ties is a part that breaks no tie.
      # This took `identified_by`, which is the SINGLE head and is nil the
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
      # QuerySpecification::Common::Comparison. This method and
      # Ports::Query::InMemory#holds? used to carry a copy each and the
      # two drifted — `none_in_state` reached only one of them, and
      # `comparable` disagreed about value objects with two numeric
      # members. What stays here is how a value is REACHED for this
      # path: the registry is instance state rather than an argument.
      def holds?(clause, held, args, record: nil, domain: nil)
        QuerySpecification::Common::Comparison.holds?(
          clause.op, comparable(held), comparable(resolve_query_value(clause.value, args)), registry: @registry
        )
      end

      def resolve_query_value(value, args)
        value.is_a?(Symbol) ? args[value] : value
      end

      def normalize_args(aggregate, declared, args)
        declared.attributes.each_with_object(args.dup) do |attribute, normalized|
          next unless normalized.key?(attribute.name)

          normalized[attribute.name] = Value.for_attribute(aggregate, attribute, normalized[attribute.name])
        end
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
                                     identity: ->(record) { record.id.to_s }) { |record|
          comparable(QuerySpecification::FieldPath.dig(record, field))
        }
      end
    end
  end
end
