require_relative "../naming"
require_relative "../ports/query"
require_relative "../ports/query/ordering"
require_relative "../query_specification/field_path"
require_relative "errors"
require_relative "refusal_wording"
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

        repository = @registry.repository(domain, aggregate)
        if (native = Ports::Query.execute(repository, declared, args, context: { domain: domain, aggregate: aggregate }))
          records = native
          return records.map { |record| { id: record.id }.merge(record.state) }
        end

        interpret(repository.all, declared, args)
      end

      # The REFERENCE answer — this interpreter's own evaluation, never an
      # adapter's native hook. The fuzzer's query oracle replays every
      # generated ask through both paths and treats a difference as a
      # finding: the differential gate the retired cross-runtime harness
      # should always have been, aimed where the divergence actually
      # lives — between the engines inside this one runtime.
      def reference_call(domain, aggregate, query_name, args)
        return entity_rows(domain, aggregate, query_name, args) if query_name.include?(".")

        declared = declared_query(aggregate, query_name)
        args = normalize_args(aggregate, declared, args)
        interpret(@registry.repository(domain, aggregate).all, declared, args)
      end

      private

      def declared_query(aggregate, query_name)
        aggregate.query(query_name) ||
          raise(UnknownVerb, RefusalWording.render("UnknownVerb", "no_query",
                                                    aggregate: aggregate.hecks_name, query: query_name.inspect))
      end

      def interpret(records, declared, args)
        matched = records.select { |r| declared.wheres.all? { |w| where_holds?(w, r, args) } }
        ordered = ordered(matched, declared.order_by, declared.null_semantics)
        capped  = declared.limit ? ordered.first(resolve_query_value(declared.limit.value, args).to_i) : ordered

        capped.map { |r| { id: r.id }.merge(r.state) }
      end

      def entity_rows(domain, aggregate, dotted, args)
        entity_name, query_name = Naming.split_dotted(dotted)
        entity = aggregate.entities.find { |piece| piece.hecks_name == entity_name } ||
                 raise(UnknownVerb, RefusalWording.render("UnknownVerb", "entity_unknown",
                                                           aggregate: aggregate.hecks_name, entity: entity_name.inspect))
        declared = entity.query(query_name) ||
                   raise(UnknownVerb, RefusalWording.render("UnknownVerb", "entity_query_missing",
                                                             entity: entity_name, query: query_name.inspect))
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

      def where_holds?(clause, record, args)
        holds?(clause, QuerySpecification::FieldPath.dig(record, clause.field), args)
      end

      def holds?(clause, held, args)
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
        when "contains" then members(held).include?(want.to_s)
        else                 held == want
        end
      end

      # gt/gte/lt/lte are numeric-only and silently false otherwise — a
      # where-clause never raises the way a given does, and that contract
      # predates this change (lt was already exactly this permissive).
      def ordered?(held, want) = held.is_a?(Numeric) && want.is_a?(Numeric)

      # in/contains both read a comma-separated list — a real Array survives
      # untouched (a bluebook's own in-process value, before any wire
      # serialisation), each element unwrapped the same way a scalar field
      # is (a list of value objects is a list of single-field hashes) ;
      # anything else is treated as CSV text — the established wire
      # convention for list-valued clauses.
      def members(value)
        return value.map { |element| comparable(element).to_s } if value.is_a?(Array)

        value.to_s.split(",").map(&:strip)
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
