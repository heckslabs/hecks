require_relative "set_transform/expressions"
require_relative "set_transform/assignments"
require_relative "../../ports/persistence/append_only"

module Hecks
  module Adapters
    # A SQL store's `set_transform` (ADR 0128): one `UPDATE … WHERE <query> AND <givens> RETURNING *`
    # for a {Ports::Persistence::SetStatement}, journalled row by row in the same transaction.
    # Mixed into an adapter that includes {SqlQueryBuilder}, whose WHERE clauses it reuses, and a
    # set dialect that supplies the SQL spellings: `typed_placeholder`, `null_safe_equality`,
    # `text_ordering`, `integer_guard`, `scalar_read`, `scalar_write`, `version_bump`,
    # `run_set_transform` and `set_transform_dialect`.
    module SetTransform
      # Raised when the store refused the statement (an overflow, a lost connection) after it was
      # sent; the transaction it ran in is rolled back.
      class Declined < StandardError; end

      include Expressions
      include Assignments

      # Compiles a statement to SQL without running it.
      #
      # @param statement [Ports::Persistence::SetStatement] the command over the query
      # @return [Array(String, Array)] the UPDATE statement and its binds in placeholder order
      # @raise [SetTransform::Uncompilable] if part of the statement has no form in this dialect
      def compile_set_transform(statement)
        build = Build.new([], [], statement.arguments || {})
        sets, conditions = set_list(statement, build)
        clauses = where_list(statement, build, conditions)
        sql = "UPDATE #{quoted_table} SET #{sets.join(", ")}"
        sql << " WHERE #{clauses.join(" AND ")}" unless clauses.empty?
        ["#{sql} RETURNING *", build.binds]
      end

      # Runs a statement and journals every row it updated, inside one transaction (joining an
      # open one).
      #
      # @param statement [Ports::Persistence::SetStatement] the command over the query
      # @return [Array<Runtime::Instance>] each updated row as it now stands, in no set order
      # @raise [SetTransform::Uncompilable] before anything is written
      # @raise [SetTransform::Declined] if the store refused the statement
      def apply_set_transform(statement)
        sql, binds = compile_set_transform(statement)
        transaction do
          instances = run_set_transform(sql, binds)
          journal_set(instances)
          instances
        end
      end

      private

      # The query's clauses, the lifecycle's conditions, the givens, then every guard compiling
      # them collected.
      def where_list(statement, build, conditions)
        wheres = query_conditions(statement, build) + conditions +
                 statement.givens.map { |node| predicate_sql(node, build) }
        wheres + build.guards.uniq
      end

      def query_conditions(statement, build)
        query = statement.query
        if query.wheres.any? { |clause| SqlQueryBuilder::IN_MEMORY_OPERATORS.include?(clause.op.to_s) } ||
           query.limit || query.offset
          raise Uncompilable, "#{dialect_name} cannot rewrite the rows of a paged or partly in-memory query"
        end

        where_clauses(query, statement.query_args || {}, build.binds)
      end

      # One journal entry per row, then the checkpoint once, as a row-by-row save would leave it.
      def journal_set(instances)
        entries = instances.map do |instance|
          append(Ports::Persistence::Entry.new(operation: "save", id: instance.id.to_s, state: instance.state.dup))
        end
        advance_checkpoint!(entries.map(&:sequence).max) unless entries.empty?
      end
    end
  end
end
