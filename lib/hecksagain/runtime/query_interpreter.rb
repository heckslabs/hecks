require_relative "../naming"
require_relative "../ports/query"
require_relative "../ports/query/ordering"
require_relative "../query_specification/field_path"
require_relative "errors"
require_relative "reference_hop"
require_relative "refusal_wording"
require_relative "tenant_scope"
require_relative "value"


module Hecksagain
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
        # (Runtime::QueryInterpreter#none_in_state?'s own vendored
        # addition) can look its target aggregate up — see
        # Ports::Query::InMemory#none_in_state?'s own comment on why an
        # ordinary aggregate-level Memory query needs this passed
        # explicitly rather than closing over an instance variable.
        if (native = Ports::Query.execute(repository, declared, args, context: { domain: domain, aggregate: aggregate, registry: @registry }))
          records = native
          # `record.state.merge(id: record.id)` — id LAST, not first. See
          # Instance#to_h's own comment: an aggregate free to declare its
          # own attribute literally named `id` has that attribute's own
          # wrapped value sitting in `record.state[:id]` already; merging
          # it OVER a `{id:}.merge(state)` used to let it silently
          # clobber the correct bare identity this row is supposed to
          # carry.
          return records.map { |record| record.state.merge(id: record.id) }
        end

        interpret(repository.all, declared, args, domain: domain)
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
        capped  = declared.limit ? ordered.first(resolve_query_value(declared.limit.value, args).to_i) : ordered

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
        matched = records.select { |r| declared.wheres.all? { |w| reference_where_holds?(w, r, args, domain: domain, shape: shape) } }
        ordered = ordered(matched, declared.order_by, declared.null_semantics)
        capped  = declared.limit ? ordered.first(resolve_query_value(declared.limit.value, args).to_i) : ordered

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
        reference_id = record[hop.attribute.name]
        return false if reference_id.nil?

        target_record = @registry.repository(domain, hop.target).find(reference_id)
        return false unless target_record

        inner = QuerySpecification::Common::WhereClause.new(field: rest, op: clause.op, value: clause.value)
        reference_where_holds?(inner, target_record, args, domain: domain, shape: hop.target)
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
        declared.limit ? ordered.first(resolve_query_value(declared.limit.value, args).to_i) : ordered
      end

      def element_where_holds?(clause, element, args)
        holds?(clause, element[clause.field.to_sym], args)
      end

      # A row's own key, however the store spells it. A sub-list row is a plain hash
      # merged from stored state, so its keys arrive as strings from one adapter and
      # symbols from another — and reading only one spelling gave every row the SAME
      # identity, which is a tie, which is the exact nondeterminism this tier exists
      # to remove. It rides `comparable` for the same reason a where-clause does : an
      # identity is a value object, and `to_s` on one is an OBJECT ADDRESS — a sort key
      # that differs run to run, which is worse than the store order it replaced.
      def cell(row, key) = row[key.to_sym] || row[key.to_s]

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

      def holds?(clause, held, args, record: nil, domain: nil)
        held = comparable(held)
        want = comparable(resolve_query_value(clause.value, args))

        case clause.op.to_s
        when "eq"       then held == want
        when "ne"       then held != want
        when "lt"       then ordered?(held, want) && held < want
        when "lte"      then ordered?(held, want) && held <= want
        when "gt"       then ordered?(held, want) && held > want
        when "gte"      then ordered?(held, want) && held >= want
        when "in"       then members(want).include?(held.to_s)
        when "contains" then contains?(held, want)
        when "none_in_state" then none_in_state?(held, want)
        else                 held == want
        end
      end

      # Vendored addition, not (yet) upstream hecksagain (migration plan
      # task 4) -- see comparators.rb's own comment on `none_in_state`
      # itself. `want` is "Aggregate:state" (a literal, never resolved
      # through `resolve_query_value`'s Symbol path -- the target names a
      # TYPE, not an argument). `held` is THIS record's own field value,
      # already unwrapped by `comparable` -- the point-lookup key. No
      # `domain:` qualifier on "Aggregate" because the corpus's own usage
      # never gives one (plan.bluebook's Story reaching Conductor's Claim)
      # -- searched by bare name across every loaded domain, the same
      # single free-text lookup `HecksagainRuntime.state` already does for
      # a caller-supplied aggregate FQN. Ambiguous (two domains declaring
      # the same aggregate name) is a real, theoretical gap -- picks the
      # first match rather than refusing, since a where-clause never
      # raises (see `ordered?`'s own comment on the same contract).
      def none_in_state?(held, want)
        aggregate_name, state = want.to_s.split(":", 2)
        target = find_aggregate_by_name(aggregate_name)
        return true unless target

        target_domain, target_ir = target
        record = @registry.repository(target_domain, target_ir).find(held)
        return true unless record

        comparable(record.state[:state]) != state
      end

      def find_aggregate_by_name(name)
        @registry.bluebooks.each do |domain, bluebook|
          aggregate = bluebook.aggregates.find { |a| a.hecks_name == name }
          return [domain, aggregate] if aggregate
        end
        nil
      end

      # gt/gte/lt/lte are numeric-only and silently false otherwise — a
      # where-clause never raises the way a given does, and that contract
      # predates this change (lt was already exactly this permissive).
      def ordered?(held, want) = held.is_a?(Numeric) && want.is_a?(Numeric)

      # `in` reads a comma-separated list — a real Array survives untouched
      # (a bluebook's own in-process value, before any wire serialisation),
      # each element unwrapped the same way a scalar field is (a list of
      # value objects is a list of single-field hashes) ; anything else is
      # treated as CSV text. This is `in`'s reading of ITS ARGUMENT (a
      # caller may legitimately pass "a,b,c" meaning "any of these") —
      # unrelated to `contains`, which reads the STORED field. See
      # `contains?`.
      def members(value)
        return value.map { |element| comparable(element).to_s } if value.is_a?(Array)

        value.to_s.split(",").map(&:strip)
      end

      # `contains` means two different things depending on what is HELD —
      # real ELEMENT membership for a `list_of` field (a genuine Array
      # arrives already, one element one member, nothing to split), and
      # plain SUBSTRING for anything else. It used to fall through to
      # `members`' comma-split for the scalar case too, silently reading a
      # free-text field's own comma as a separator — which the SQL side's
      # `instr`/`position` never did, so the two disagreed the moment a
      # scalar's real content held a comma. Matching SQL's substring
      # reading here, rather than the other way around, keeps every
      # engine answering `contains` identically for the same declared field.
      def contains?(held, want)
        return members(held).include?(want.to_s) if held.is_a?(Array)

        held.to_s.include?(want.to_s)
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

      def comparable(value)
        value = value.to_h if value.is_a?(Value)
        if value.is_a?(Hash)
          scalars = value.values.select { |field| field.is_a?(Numeric) }
          return scalars.first if scalars.size == 1
          return value.values.first if value.size == 1
        end

        value
      end

      def ordered(records, order_by, null_semantics = nil)
        field = order_by&.field
        Ports::Query::Ordering.apply(records, order_by, null_semantics,
                                     identity: ->(record) { record.id.to_s }) { |record| comparable(record[field]) }
      end
    end
  end
end
