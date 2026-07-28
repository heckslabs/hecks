# QueryInterpreter — the questions, answered.
#
# Seven queries in banking alone — where / order_by / desc / limit / a
# caller-supplied :floor — parsed, reached the IR, agreed byte-for-byte… and
# neither runtime could RUN one. The fourth construct in the same silence
# (policies, sagas, lifecycles before it).
#
# A query filters the store through the port, orders, caps, and answers full
# records — id first, then state. It never writes, so it is the one room with
# no consequences to sequence : the door hands it a resolved aggregate and
# takes back rows.
#
#   QueryInterpreter.new(registry).call(domain, aggregate, "in_flight", args)

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

      # An entity query reads ELEMENTS across every parent record : each row
      # is the element plus the parent's id under the parent's snake_case
      # name — `account: "acct-1"` — because an element's address outside
      # the boundary always includes whose boundary it is. Same eq/lt
      # vocabulary, same ordering rules, one level down.
      def entity_rows(domain, aggregate, dotted, args)
        entity_name, query_name = dotted.split(".", 2)
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
        sorted = rows.sort_by do |row|
          value = row[field]
          value.is_a?(Numeric) ? [0, value, ""] : [1, 0, value.to_s]
        end
        order_by.direction.to_s == "desc" ? sorted.reverse : sorted
      end

      def where_holds?(clause, record, args)
        holds?(clause, record[clause.field], args)
      end

      # eq and lt are the whole vocabulary the DSL admits today. A clause
      # value is a literal, or a :symbol naming one of the query's own
      # attributes, resolved from the caller.
      #
      # A record reads its field by name and an element by symbol, which is the
      # ONLY difference between the two — so the comparison itself is written
      # once. `lt` demands both sides be numbers rather than coercing, for the
      # same reason arithmetic does : a silent comparison is worse than none.
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

      # Numeric fields sort as numbers, everything else as text, ties break
      # on id — spelled out because BOTH runtimes must sort identically or
      # the harness drowns in ordering noise that means nothing.
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
