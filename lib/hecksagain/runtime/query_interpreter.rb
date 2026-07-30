
module Hecksagain
  module Runtime
    class QueryInterpreter
      attr_reader :registry

      def initialize(registry)
        @registry = registry
      end

      def call(domain, aggregate, query_name, args)
        return entity_rows(domain, aggregate, query_name, args) if query_name.include?(".")

        declared = aggregate.query(query_name) ||
                   raise(UnknownVerb, "#{aggregate.hecks_name} has no query #{query_name.inspect}")
        args = normalize_args(aggregate, declared, args)

        repository = @registry.repository(domain, aggregate)
        if (native = Ports::Query.execute(repository, declared, args, context: { domain: domain, aggregate: aggregate }))
          records = native
          return records.map { |record| { id: record.id }.merge(record.state) }
        end

        records = repository.all
        matched = records.select { |r| declared.wheres.all? { |w| where_holds?(w, r, args) } }
        ordered = ordered(matched, declared.order_by, declared.null_semantics)
        capped  = declared.limit ? ordered.first(resolve_query_value(declared.limit.value, args).to_i) : ordered

        capped.map { |r| { id: r.id }.merge(r.state) }
      end

      private

      def entity_rows(domain, aggregate, dotted, args)
        entity_name, query_name = Naming.split_dotted(dotted)
        entity = aggregate.entities.find { |piece| piece.hecks_name == entity_name } ||
                 raise(UnknownVerb, "#{aggregate.hecks_name} has no entity #{entity_name.inspect}")
        declared = entity.query(query_name) ||
                   raise(UnknownVerb, "#{entity_name} has no query #{query_name.inspect}")
        list_attr = aggregate.attributes.find { |a| a.list? && a.type.to_s == entity_name } ||
                    raise(UnknownVerb, "#{aggregate.hecks_name} holds no list of #{entity_name}")

        parent_key = Naming.reference_key(aggregate.hecks_name)
        rows = @registry.repository(domain, aggregate).all.flat_map do |record|
          Array(record[list_attr.name])
            .select { |el| declared.wheres.all? { |w| element_where_holds?(w, el, args) } }
            .map    { |el| { parent_key => record.id }.merge(el) }
        end

        ordered = declared.order_by ? ordered_elements(rows, declared.order_by, declared.null_semantics) : rows
        declared.limit ? ordered.first(resolve_query_value(declared.limit.value, args).to_i) : ordered
      end

      def element_where_holds?(clause, element, args)
        holds?(clause, element[clause.field.to_sym], args)
      end

      def ordered_elements(rows, order_by, null_semantics = nil)
        field  = order_by.field.to_sym
        rows = QuerySpecification::Common::NullPolicy.order(rows, direction: order_by.direction,
                                                             policy: null_semantics) { |row| comparable(row[field]) }
        rows
      end

      def where_holds?(clause, record, args)
        holds?(clause, record[clause.field], args)
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
      # anything else is treated as CSV text, matching the convention Rust's
      # parser and the SQLite adapter already use.
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
        return records unless order_by

        field  = order_by.field
        QuerySpecification::Common::NullPolicy.order(records, direction: order_by.direction,
                                                     policy: null_semantics) { |record| comparable(record[field]) }
      end
    end
  end
end
