module Hecksagain
  module Ports
    # Common query execution boundary. Adapters expose one optional native
    # hook; all other query behavior remains in the shared interpreter.
    module Query
      class Unsupported < StandardError; end

        # What order an ask ANSWERS IN — the meaning of the ask, not a property
        # of the store that happens to hold it. Declared here once so an adapter
        # may satisfy it natively but never redefine it : SQLite pushes both
        # tiers into SQL (NullPolicy.sql_order renders `field DIR, id DIR`),
        # while Heki and Memory have no query engine and delegate straight back
        # to InMemory below.
        #
        # Two tiers, in this order : the DECLARED order_by when there is one,
        # then IDENTITY, always. The identity tier is what makes an ask total.
        # Without it, an ask with no order_by — or a declared order with tied
        # keys — hands back whatever order the store happened to hold, which is
        # how a heki-backed Ruby and a heki-backed Rust came to disagree while
        # every hand-written query in the corpus stayed green : not one of them
        # had a tie for the two runtimes to disagree about.
        #
        # An adapter that pushes ordering down MUST push limit down with it.
        # Re-ordering a page the store already cut would be a top-N of the
        # wrong N — the one way this can be got quietly, expensively wrong.
        module Ordering
          module_function

          def apply(rows, order_by, null_semantics = nil, identity:, &value_of)
            # STABLE, because sort_by is not : two rows whose identity ties would
            # otherwise swap arbitrarily, and a tier meant to REMOVE store-dependence
            # would be adding a coin flip of its own.
            rows = rows.each_with_index.sort_by { |row, index| [identity.call(row), index] }.map(&:first)
            return rows unless order_by

            QuerySpecification::Common::NullPolicy.order(
              rows, direction: order_by.direction, policy: null_semantics, &value_of
            )
          end
        end

        module InMemory
        module_function

        def execute(records, declared, args = {})
          matched = records.select do |record|
            declared.wheres.all? { |clause| holds?(clause, comparable(record[clause.field]), args) }
          end
          field   = declared.order_by&.field&.to_sym
          matched = Ordering.apply(matched, declared.order_by, declared.null_semantics,
                                   identity: ->(record) { record.id.to_s }) { |record| comparable(record[field]) }
          matched = matched.first(resolve(declared.limit.value, args).to_i) if declared.limit
          matched = matched.drop(resolve(declared.offset.value, args).to_i) if declared.offset
          matched
        end

        # The same 8 comparators QuerySpecification::Common::COMPARATORS
        # declares. This is the path that actually runs for a memory- or
        # heki-backed aggregate query ; QueryInterpreter#holds? only runs for
        # entity/sub-list queries, or when no adapter implements :query at all.
        def holds?(clause, held, args)
          want = comparable(resolve(clause.value, args))

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

        def ordered?(held, want) = held.is_a?(Numeric) && want.is_a?(Numeric)

        # A list of value objects is a list of single-field hashes — unwrap
        # each element the same way a scalar field is, before stringifying.
        def members(value)
          return value.map { |element| comparable(element).to_s } if value.is_a?(Array)

          value.to_s.split(",").map(&:strip)
        end

        def resolve(value, args) = value.is_a?(Symbol) ? args[value] : value

        def comparable(value)
          value = value.to_h if value.is_a?(Runtime::Value)
          if value.is_a?(Hash)
            numeric = value.values.find { |field| field.is_a?(Numeric) }
            return numeric if numeric
            return value.values.first if value.size == 1
          end
          value
        end
      end

      module_function

      def execute(repository, specification, args = {}, context: {})
        adapter = repository.respond_to?(:adapter) ? repository.adapter : repository
        return nil unless adapter.respond_to?(:query)

        validate!(specification, adapter)
        adapter.query(specification, args, context: context)
      end

      def validate!(specification, adapter)
        if specification.cursor && specification.offset
          raise Unsupported, "a query cannot combine cursor and offset pagination"
        end

        return if specification.inspection.nil? || adapter.respond_to?(:inspect_query)
        return if specification.inspection.mode.to_s == "sql" && adapter.respond_to?(:query)

        raise Unsupported, "#{adapter.class} cannot inspect generated queries"
      end
    end
  end
end
