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
require_relative "query_interpreter/arguments"
require_relative "query_interpreter/entity_rows"
require_relative "query_interpreter/outside_answer"

module Hecks
  module Runtime
    # Answers one declared aggregate or entity query against a repository, using a
    # native adapter hook when the store has one and interpreting the query otherwise.
    class QueryInterpreter
      include Arguments
      include EntityRows
      include OutsideAnswer

      attr_reader :registry

      def initialize(registry)
        @registry = registry
      end

      # Answers one declared aggregate or entity query, preferring a native adapter
      # hook and falling back to interpreting it over every loaded record.
      #
      # @param query_name [String] a declared name, or an entity query's `"Entity.Query"`
      # @return [Array<Hash>] one frozen Hash per matching record, `:id` merged in last
      # @raise [Runtime::UnknownVerb] if `query_name` names no declared query
      # @raise [Runtime::TypeMismatch] if an argument cannot be coerced to its type
      # @raise [Runtime::WiringError] if the aggregate's repository cannot be resolved
      def call(domain, aggregate, query_name, args)
        return entity_rows(domain, aggregate, query_name, args) if query_name.include?(".")

        declared = declared_query(aggregate, query_name)
        args = normalize_args(aggregate, declared, args)
        port = aggregate.query_binding(declared.name)
        return answered_from_outside(aggregate, declared, args, port) if port

        Freezer.deep(local_answer(domain, aggregate, declared, args))
      end

      # The reference answer: this interpreter's own evaluation, never a native hook.
      # The fuzzer's query oracle diffs it against #call.
      #
      # Hop clauses use a deliberately naive walk (reference_where_holds?), not
      # ReferenceHop's fold; sharing that would blind the oracle to it.
      #
      # @return [Array<Hash>] one Hash per matching record, `:id` merged in last
      # @raise [Runtime::UnknownVerb] if `query_name` names no declared query
      # @raise [Runtime::TypeMismatch] if an argument cannot be coerced to its type
      def reference_call(domain, aggregate, query_name, args)
        return entity_rows(domain, aggregate, query_name, args) if query_name.include?(".")

        declared = declared_query(aggregate, query_name)
        args = normalize_args(aggregate, declared, args)
        # No records to interpret: the adapter is the only answer there is, and the reference
        # takes it through the same shape check, so a diff against #call sees only the adapter.
        port = aggregate.query_binding(declared.name)
        return answered_from_outside(aggregate, declared, args, port) if port

        declared = TenantScope.apply(declared, args)
        reference_interpret(@registry.repository(domain, aggregate).all, declared, args,
                            domain: domain, shape: aggregate)
      end

      private

      # The rows of a query answered from the aggregate's own records: the adapter's native hook
      # when the store has one, this interpreter's evaluation otherwise.
      def local_answer(domain, aggregate, declared, args)
        declared = TenantScope.apply(declared, args)
        # Applied after TenantScope so its tenant clause rides through as an ordinary
        # local clause; it is deliberately not propagated into the hop's inner query.
        declared = ReferenceHop.apply(declared, args, registry: @registry, domain: domain, aggregate: aggregate)

        repository = @registry.repository(domain, aggregate)
        # `registry:` lets a `none_in_state` where-clause look up its target aggregate.
        native = Ports::Query.execute(repository, declared, args,
                                      context: { domain: domain, aggregate: aggregate, registry: @registry })
        return rows_of(native) if native

        interpret(repository.all, declared, args, domain: domain)
      end

      # `id` merges last so an aggregate attribute named `id` cannot clobber the
      # bare identity (see Instance#to_h). Rows are frozen by the caller: a mutated row would
      # edit nobody's state and disagree with the store.
      def rows_of(records) = records.map { |record| record.state.merge(id: record.id) }

      def declared_query(aggregate, query_name)
        aggregate.query(query_name) ||
          raise(UnknownVerb, RefusalWording.render_site("UnknownVerb", "no_query",
                                                        aggregate: aggregate.hecks_name, query: query_name))
      end

      def interpret(records, declared, args, domain: nil)
        matched = records.select { |r| declared.wheres.all? { |w| where_holds?(w, r, args, domain: domain) } }
        rows_of(paginate(ordered(matched, declared.order_by, declared.null_semantics), declared, args))
      end

      # Twin of `interpret` for reference_call: hop clauses go through
      # reference_where_holds?, which `where_holds?` cannot follow.
      def reference_interpret(records, declared, args, domain:, shape:)
        matched = records.select do |r|
          declared.wheres.all? do |w|
            reference_where_holds?(w, r, args, domain: domain, shape: shape)
          end
        end
        rows_of(paginate(ordered(matched, declared.order_by, declared.null_semantics), declared, args))
      end

      # Offset before limit, as SQL's `LIMIT n OFFSET m` and Ports::Query::InMemory do.
      def paginate(ordered, declared, args)
        skipped = declared.offset ? ordered.drop(resolve_query_value(declared.offset.value, args).to_i) : ordered
        declared.limit ? skipped.first(resolve_query_value(declared.limit.value, args).to_i) : skipped
      end

      # Walks each reference by hand. A nil or dangling reference makes the whole clause
      # false whatever the comparator; comparing nil directly would answer `ne` true.
      def reference_where_holds?(clause, record, args, domain:, shape:)
        step = QuerySpecification::HopPath.next_hop(clause.field, shape.attributes)
        return where_holds?(clause, record, args) unless step

        hop, rest = step
        inner = QuerySpecification::Common::WhereClause.new(field: rest, op: clause.op, value: clause.value)
        hop_reference_ids(record, hop).any? do |reference_id|
          hop_holds?(inner, reference_id, args, domain, hop)
        end
      end

      def hop_reference_ids(record, hop)
        held = record[hop.attribute.name]
        (hop.attribute.list? ? Array(held) : [held]).compact
      end

      def hop_holds?(inner, reference_id, args, domain, hop)
        target_record = @registry.repository(domain, hop.target).find(reference_id)
        return false unless target_record

        reference_where_holds?(inner, target_record, args, domain: domain, shape: hop.target)
      end

      def where_holds?(clause, record, args, domain: nil)
        holds?(clause, QuerySpecification::FieldPath.dig(record, clause.field), args, record: record, domain: domain)
      end

      # The comparator table is shared with Ports::Query::InMemory#holds? through
      # QuerySpecification::Common::Comparison so the two cannot drift.
      def holds?(clause, held, args, record: nil, domain: nil)
        QuerySpecification::Common::Comparison.holds?(
          clause.op, comparable(held), comparable(resolve_query_value(clause.value, args)), registry: @registry
        )
      end

      def resolve_query_value(value, args)
        value.is_a?(Symbol) ? args[value] : value
      end

      def comparable(value) = QuerySpecification::Common::Comparison.comparable(value)

      # FieldPath.dig, not `record[field]`: a dotted order_by is one symbol key that
      # `Instance#[]` never holds, so it would sort by all-nil.
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
