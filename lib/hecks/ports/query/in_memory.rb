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

        # Filters, orders and pages `records` against a declared query specification.
        #
        # @param records [Array<Runtime::Instance, Hash>] the candidate records to filter —
        #   an Instance, a Value, or a plain row hash per record (see `FieldPath.dig`)
        # @param declared [QuerySpecification::Common::Options,
        #   Bluebook::Behaviour::ReadModel::FilteredOptions] the specification providing
        #   `wheres`, `order_by`, `offset` and `limit`
        # @param args [Hash{Symbol => Object}] bound values for any Symbol placeholder in a
        #   where clause, `offset`, or `limit`
        # @param registry [Runtime::Registry, nil] the booted registry, passed through to a
        #   registry-aware comparison; nil when none is available
        # @return [Array<Runtime::Instance, Hash>] the matching records, ordered and paged;
        #   the same element type as `records`
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

        # The comparator table itself lives in
        # QuerySpecification::Common::Comparison, not duplicated per
        # caller — this module and Runtime::QueryInterpreter drifted
        # when each carried its own copy (see that file's own comment
        # for what it cost). What stays here is how a value is reached
        # for this path: a registry arrives as an argument rather than
        # as instance state, and the field is dug through FieldPath
        # before it arrives.
        # @param clause [QuerySpecification::Common::WhereClause] the declared comparison
        # @param held [Object, nil] the record's own value for `clause.field`
        # @param args [Hash{Symbol => Object}] bound values for a Symbol-named `clause.value`
        # @param registry [Runtime::Registry, nil] used only by `none_in_state`; see
        #   `Comparison.holds?`
        # @return [Boolean] whether the comparison holds
        # @raise [Runtime::WiringError] if `clause.op` names no comparator in
        #   `Comparison`'s table, or `none_in_state`'s target aggregate has no wired repository
        def holds?(clause, held, args, registry: nil)
          Comparison.holds?(clause.op, held, comparable(resolve(clause.value, args)), registry: registry)
        end

        # Resolves a where-clause value, looking up a Symbol placeholder in `args`.
        #
        # @param value [Object] a literal value, or a Symbol naming a key in `args`
        # @param args [Hash{Symbol => Object}] bound argument values
        # @return [Object] `args[value]` when `value` is a Symbol, else `value` unchanged
        def resolve(value, args) = value.is_a?(Symbol) ? args[value] : value

        # Normalises a value into the shape `Comparison` compares against.
        #
        # @param value [Runtime::Value, Hash, Object, nil] a held or wanted value; a
        #   `Runtime::Value` is read through its `to_h`
        # @return [Object, nil] the sole numeric member, or the sole member, of a Hash-shaped
        #   value; otherwise `value` unchanged
        def comparable(value) = Comparison.comparable(value)
      end
    end
  end
end
