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

        # Filters, orders and pages an Array of records against a declared query, in Ruby.
        #
        # @param records [Array<Runtime::Instance>] the whole candidate set to filter; each
        #   must answer `id`, read by the identity tier of the order
        # @param declared [QuerySpecification::Common::Options] the declared query: its
        #   `wheres`, `order_by`, `null_semantics`, `offset` and `limit` are read
        # @param args [Hash{Symbol => Object}] the caller's arguments, which a where-clause,
        #   limit or offset written as a Symbol reads its value from
        # @param registry [Runtime::Registry, nil] threaded through to `holds?` for a
        #   `none_in_state` where-clause to look its target aggregate up; nil makes that
        #   comparator hold unconditionally
        # @return [Array<Runtime::Instance>] the matching records, ordered and paged; `[]`
        #   when none match
        # @raise [Runtime::WiringError] if a where-clause names an operation no comparator
        #   handles
        def execute(records, declared, args = {}, registry: nil)
          matched = records.select do |record|
            declared.wheres.all? do |clause|
              holds?(clause, comparable(FieldPath.dig(record, clause.field)), args, registry: registry)
            end
          end
          field   = declared.order_by&.field
          matched = Ordering.apply(matched, declared.order_by, declared.null_semantics,
                                   identity: ->(record) { record.id.to_s }) { |record| comparable(FieldPath.dig(record, field)) }
          # **Offset first, then limit** — the order SQL means by `LIMIT n
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
          # taking ten and then dropping ten leaves nothing, so page two
          # of a memory-backed query came back empty however many rows
          # were really there.
          matched = matched.drop(resolve(declared.offset.value, args).to_i) if declared.offset
          matched = matched.first(resolve(declared.limit.value, args).to_i) if declared.limit
          matched
        end

        # Decides whether one where-clause holds, dispatching to the shared comparator table.
        #
        # The comparator table itself lives in
        # QuerySpecification::Common::Comparison, shared with
        # Runtime::QueryInterpreter rather than each carrying its own copy
        # of it — two copies drifted before this was extracted (see that
        # file's own comment for what it cost). What
        # stays here is how a value is reached for this path: a registry
        # arrives as an argument rather than as instance state, and the
        # field is dug through FieldPath before it arrives.
        #
        # @param clause [QuerySpecification::Common::WhereClause] the where-clause to test
        # @param held [Object, nil] the record's own comparable value for the clause's field
        # @param args [Hash{Symbol => Object}] the caller's arguments, read when the
        #   clause's value is a Symbol
        # @param registry [Runtime::Registry, nil] passed to `Comparison.holds?` for a
        #   `none_in_state` clause; nil makes that comparator hold unconditionally
        # @return [Boolean] whether the clause holds
        # @raise [Runtime::WiringError] if the clause names an operation no comparator
        #   handles
        def holds?(clause, held, args, registry: nil)
          Comparison.holds?(clause.op, held, comparable(resolve(clause.value, args)), registry: registry)
        end

        # Reads a where-clause, limit or offset value, substituting a caller argument for a
        # Symbol.
        #
        # @param value [Object] the declared value; a Symbol names a key in `args`, anything
        #   else is a literal
        # @param args [Hash{Symbol => Object}] the caller's arguments
        # @return [Object, nil] `args[value]` when `value` is a Symbol (nil if the key is
        #   absent), otherwise `value` unchanged
        def resolve(value, args) = value.is_a?(Symbol) ? args[value] : value

        # Reduces a Hash-shaped held or wanted value to its single comparable member.
        #
        # @param value [Runtime::Value, Hash, Object, nil] a held or wanted value; a
        #   `Runtime::Value` is read through its `to_h`
        # @return [Object, nil] the sole numeric member, or the sole member, of a Hash-shaped
        #   value; otherwise `value` unchanged (see `Comparison.comparable`)
        def comparable(value) = Comparison.comparable(value)
      end
    end
  end
end
