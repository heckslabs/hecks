module Hecks
  module Translation
    # Compiles a `Bluebook::TranslationExpression` tree into a Postgres text expression over a
    # jsonb record. The compiled form yields NULL wherever the expression has no value, and
    # agrees with `TranslationExpression.evaluate` on every record.
    module ExpressionSql
      UPPER = ("A".."Z").to_a.join.freeze
      LOWER = UPPER.downcase.freeze

      module_function

      # @param tree [Array] a tree `Bluebook::TranslationExpression.parse` returned
      # @param record [String] the SQL that names the jsonb record the expression reads
      # @return [String] a SQL expression of type text
      def compile(tree, record)
        case tree.first
        when "lit" then text(tree[1])
        when "null" then "NULL::text"
        when "ref" then reference(tree[1], record)
        else function(tree.first, tree.drop(1), record)
        end
      end

      def function(name, arguments, record)
        return lookup(arguments, record) if name == "lookup"

        parts = arguments.map { |argument| compile(argument, record) }
        case name
        when "lower" then "translate(#{parts.first}, #{text(UPPER)}, #{text(LOWER)})"
        when "upper" then "translate(#{parts.first}, #{text(LOWER)}, #{text(UPPER)})"
        when "concat" then "(#{parts.join(" || ")})"
        else "replace(#{parts.join(", ")})"
        end
      end

      # Only text counts as a value: a number, object, array or null reads as no value.
      def reference(path, record)
        at = RuleCompiler.path_literal(path)
        "(CASE WHEN jsonb_typeof(#{record} #> #{at}) = 'string' THEN #{record} #>> #{at} END)"
      end

      def lookup(arguments, record)
        key, table, fallback = arguments
        branches = table.map { |from, to| "WHEN #{text(from)} THEN #{text(to)}" }.join(" ")
        "(SELECT CASE WHEN __v IS NULL THEN NULL ELSE CASE __v #{branches} ELSE #{compile(fallback, record)} END END " \
          "FROM (SELECT #{compile(key, record)} AS __v) __lookup)"
      end

      def text(value) = "#{RuleCompiler.text_literal(value)}::text"
    end
  end
end
