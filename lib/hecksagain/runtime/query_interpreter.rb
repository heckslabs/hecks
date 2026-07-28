
module Hecksagain
  module Runtime
    class QueryInterpreter
      attr_reader :registry

      def initialize(registry)
        @registry = registry
      end

      def call(domain, aggregate, query_name, args)
        return entity_rows(domain, aggregate, query_name, args) if query_name.include?(".")

        declared = aggregate.queries.find { |q| q.name == query_name } ||
                   raise(UnknownVerb, "#{aggregate.name} has no query #{query_name.inspect}")

        records = @registry.repository(domain, aggregate).all
        matched = records.select { |r| declared.wheres.all? { |w| where_holds?(w, r, args) } }
        ordered = ordered(matched, declared.order_by)
        capped  = declared.limit ? ordered.first(resolve_query_value(declared.limit.value, args).to_i) : ordered

        capped.map { |r| { id: r.id }.merge(r.state) }
      end

      private

      def entity_rows(domain, aggregate, dotted, args)
        entity_name, query_name = Naming.split_dotted(dotted)
        entity = aggregate.entities.find { |e| e.name == entity_name } ||
                 raise(UnknownVerb, "#{aggregate.name} has no entity #{entity_name.inspect}")
        declared = entity.query(query_name) ||
                   raise(UnknownVerb, "#{entity_name} has no query #{query_name.inspect}")
        list_attr = aggregate.attributes.find { |a| a.list? && a.type.to_s == entity_name } ||
                    raise(UnknownVerb, "#{aggregate.name} holds no list of #{entity_name}")

        parent_key = Naming.reference_key(aggregate.name)
        rows = @registry.repository(domain, aggregate).all.flat_map do |record|
          Array(record[list_attr.name])
            .select { |el| declared.wheres.all? { |w| element_where_holds?(w, el, args) } }
            .map    { |el| { parent_key => record.id }.merge(el) }
        end

        ordered = declared.order_by ? ordered_elements(rows, declared.order_by) : rows
        declared.limit ? ordered.first(resolve_query_value(declared.limit.value, args).to_i) : ordered
      end

      def element_where_holds?(clause, element, args)
        holds?(clause, element[clause.field.to_sym], args)
      end

      def ordered_elements(rows, order_by)
        field  = order_by.field.to_sym
        sorted = rows.each_with_index.sort_by do |row, index|
          value = row[field]
          value.is_a?(Numeric) ? [0, value, "", index] : [1, 0, value.to_s, index]
        end.map(&:first)
        order_by.direction.to_s == "desc" ? sorted.reverse : sorted
      end

      def where_holds?(clause, record, args)
        holds?(clause, record[clause.field], args)
      end

      def holds?(clause, held, args)
        want = resolve_query_value(clause.value, args)

        case clause.op.to_s
        when "lt" then held.is_a?(Numeric) && want.is_a?(Numeric) && held < want
        else           held == want
        end
      end

      def resolve_query_value(value, args)
        value.is_a?(Symbol) ? args[value] : value
      end

      def ordered(records, order_by)
        return records unless order_by

        field  = order_by.field
        sorted = records.sort_by do |r|
          value = r[field]
          value.is_a?(Numeric) ? [0, value, 0, r.id.to_s] : [1, 0, value.to_s, r.id.to_s]
        end
        order_by.direction.to_s == "desc" ? sorted.reverse : sorted
      end
    end
  end
end
