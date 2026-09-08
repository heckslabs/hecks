require_relative "ordering"
require_relative "../../runtime/value"
require_relative "../../query_specification/field_path"
require_relative "../../query_specification/common/comparison"

module Hecks
  module Ports
    module Query
      # In-memory implementation of a declared query specification:
      # applies wheres/order_by/offset/limit directly to an Array of
      # records instead of compiling SQL. Deliberately kept in exact
      # LIMIT/OFFSET-order agreement with SqlQueryBuilder (see #execute's
      # own comment) so a query answers the same page regardless of
      # which adapter backs it.
      module InMemory
        FieldPath = QuerySpecification::FieldPath
        Comparison = QuerySpecification::Common::Comparison

        module_function

        def execute(records, declared, args = {}, registry: nil)
          matched = records.select do |record|
            declared.wheres.all? do |clause|
              holds?(clause, comparable(FieldPath.dig(record, clause.field)), args, registry: registry)
            end
          end
          field   = declared.order_by&.field
          matched = Ordering.apply(matched, declared.order_by, declared.null_semantics,
                                   identity: ->(record) { record.id.to_s }) { |record| comparable(FieldPath.dig(record, field)) }
          # OFFSET FIRST, THEN LIMIT — the order SQL means by `LIMIT n
          # OFFSET m`, which is what `SqlQueryBuilder` emits and therefore
          # what every SQL-backed aggregate already answers. Written the
          # other way round here, and the two engines disagreed on the
          # same declaration: `limit 2, offset 1` over three rows is rows
          # two and three in Postgres and Sqlite, and was row two alone in
          # memory. Silently — a short page reads exactly like a page that
          # ran out of rows.
          #
          # It gets worse the further you page, which is the case nobody
          # writing the first page ever sees: at `limit 10, offset 10`,
          # taking ten and then dropping ten leaves NOTHING, so page two
          # of a memory-backed query came back empty however many rows
          # were really there.
          matched = matched.drop(resolve(declared.offset.value, args).to_i) if declared.offset
          matched = matched.first(resolve(declared.limit.value, args).to_i) if declared.limit
          matched
        end

        # The comparator table itself lives in
        # QuerySpecification::Common::Comparison — this module and
        # Runtime::QueryInterpreter used to carry a copy each, and the two
        # drifted (see that file's own comment for what it cost). What
        # stays here is how a value is REACHED for this path: a registry
        # arrives as an argument rather than as instance state, and the
        # field is dug through FieldPath before it arrives.
        def holds?(clause, held, args, registry: nil)
          Comparison.holds?(clause.op, held, comparable(resolve(clause.value, args)), registry: registry)
        end

        def resolve(value, args) = value.is_a?(Symbol) ? args[value] : value

        def comparable(value) = Comparison.comparable(value)
      end
    end
  end
end
