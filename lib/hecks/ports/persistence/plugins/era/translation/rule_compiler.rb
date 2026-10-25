require "json"
require_relative "expression_sql"

module Hecks
  module Translation
    # Compiles one TranslationAggregate's declared rules into a jsonb-transforming SQL
    # expression, shared by Ruby's own mint path and any other SQL-emitting caller. Each rule's
    # Postgres form is a template read from the translation execution ledger
    # (`lib/hecks/grammar/translation_rules.json`); this module only fills its holes.
    module RuleCompiler
      module_function

      # Every admitted rule kind's Postgres template, read once from the replayed ledger.
      #
      # @return [Hash{String => String}] rule kind to its template, with `%{name}` holes
      def postgres_forms
        @postgres_forms ||= begin
          require "hecks/grammar"
          Grammar.rule_executions("postgres").freeze
        end
      end

      # Fills one rule kind's Postgres template.
      #
      # @param kind [String] the rule kind, such as `"rename"`
      # @param holes [Hash{Symbol => String}] the SQL each `%{name}` hole takes
      # @return [String] the filled SQL
      def form(kind, **holes) = format(postgres_forms.fetch(kind), **holes)

      # Compiles one edge's derive/rename/move/convert/drop/backfill rules into a nested
      # SQL expression over `state`, composed innermost-first in that phase order.
      def compile_rules(declared)
        expression = compile_derives("state", declared.derives)
        expression = compile_renames(expression, declared.renames)
        expression = compile_moves(expression, declared.moves)
        expression = compile_converts(expression, declared.converts)
        expression = compile_drops(expression, declared.drops)
        # Backfilled last, same order as `Lineage#translate`'s in-process pass, so the
        # boot-time mint audit (which reads only this compiled SQL) sees the same result.
        compile_backfills(expression, declared.backfills)
      end

      # Wraps `expression` in each derive, every one reading the record as it was stored.
      def compile_derives(expression, derives)
        derives.inject(expression) { |sql, derive| compile_derive(sql, derive) }
      end

      # Wraps `expression` so a derive's text lands at its destination when the expression has a
      # value; the expression reads the stored `state`, never the rules composed before it.
      def compile_derive(expression, derive)
        form("derive", expression: expression, to: path_literal(derive.to),
                       value: ExpressionSql.compile(derive.tree, "state"), rule: text_literal("derive #{derive.to}"))
      end

      # Folds each rule of one kind into `expression`, innermost-first.
      def compile_renames(expression, renames)
        renames.inject(expression) { |sql, (old_name, new_name)| compile_rename(sql, old_name, new_name) }
      end

      def compile_moves(expression, moves) = moves.inject(expression) { |sql, move| compile_move(sql, move) }

      def compile_converts(expression, converts) = converts.inject(expression) { |sql, convert| compile_convert(sql, convert) }

      def compile_drops(expression, drops) = drops.inject(expression) { |sql, name| compile_drop(sql, name) }

      def compile_backfills(expression, backfills)
        backfills.inject(expression) { |sql, backfill| compile_backfill(sql, backfill) }
      end

      # Wraps `expression` in the rename of one top-level key.
      def compile_rename(expression, old_name, new_name)
        form("rename", expression: expression, from: text_literal(old_name), to: text_literal(new_name))
      end

      # Wraps `expression` in the move of one path to another.
      def compile_move(expression, move)
        form("move", expression: expression, from: path_literal(move.from), to: path_literal(move.to),
                     rule: text_literal("move #{move.from} to: #{move.to}"))
      end

      # Wraps `expression` in the conversion of one path's value through a lookup table.
      def compile_convert(expression, convert)
        pairs = JSON.generate(convert.values.map { |key, value| [key, value] })
        form("convert", expression: expression, from: path_literal(convert.from), to: path_literal(convert.to),
                        values: text_literal(pairs), source: text_literal(convert.from),
                        rule: text_literal("convert #{convert.from} to: #{convert.to}"))
      end

      # Wraps `expression` in the removal of one path.
      def compile_drop(expression, name)
        form("drop", expression: expression, path: path_literal(name))
      end

      # Reports whether an edge's declared rules for an aggregate include a rekey, read
      # directly off the raw IR like every other rule kind `compile_rules` checks.
      def rekeyed?(declared) = declared && !declared.rekeys.empty?

      # Builds a `CASE WHEN ... END AS aggregate_id` expression that only overrides
      # `aggregate_id` when `guard` matches, leaving the common no-rekey case untouched.
      def id_case(guard, declared)
        "CASE WHEN #{guard} THEN #{compile_id_expression(declared)} ELSE aggregate_id END AS aggregate_id"
      end

      # A `rekey_to` id: the value of the derive it names, read from the record's stored `state`,
      # or the old id for a record where the derive has no value.
      def compile_id_expression(declared)
        rekey = declared.rekeys.first
        derive = declared.derives.find { |candidate| candidate.to == rekey.to }
        form("rekey_to", value: ExpressionSql.compile(derive.tree, "state"))
      end

      # Wraps `expression` so a backfill's default lands at its declared path only when
      # nothing is already there, the same rule `Lineage#translate`'s own pass holds to.
      def compile_backfill(expression, backfill)
        name = backfill.name.to_s
        form("backfill", expression: expression, path: path_literal(name),
                         default: text_literal(JSON.generate(backfill.default)), rule: text_literal("backfill #{name}"))
      end

      # Renders a Ruby value as a single-quoted SQL text literal, escaping embedded quotes.
      def text_literal(text) = "'#{text.to_s.gsub("'", "''")}'"

      # Renders a dotted path as a SQL `text[]` array literal, one element per segment.
      def path_literal(path)
        segments = path.to_s.split(".").map { |segment| text_literal(segment) }
        "ARRAY[#{segments.join(", ")}]::text[]"
      end
    end
  end
end
