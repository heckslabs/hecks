require "json"

module Hecks
  module Translation
    # Compiles one TranslationAggregate's declared rules into a jsonb-transforming SQL
    # expression, shared by Ruby's own mint path and any other SQL-emitting caller.
    module RuleCompiler
      module_function

      # Compiles one edge's rename/move/convert/drop/compute/backfill rules into a nested
      # SQL expression over `state`, composed innermost-first in that phase order.
      def compile_rules(declared)
        expression = compile_renames("state", declared.renames)
        expression = compile_moves(expression, declared.moves)
        expression = compile_converts(expression, declared.converts)
        expression = compile_drops(expression, declared.drops)
        expression = compile_computes(expression, declared.computes)
        # Backfilled last, same order as `Lineage#translate`'s in-process pass, so the
        # boot-time mint audit (which reads only this compiled SQL) sees the same result.
        compile_backfills(expression, declared.backfills)
      end

      # Folds each rule of one kind into `expression`, innermost-first.
      def compile_renames(expression, renames)
        renames.inject(expression) { |sql, (old_name, new_name)| compile_rename(sql, old_name, new_name) }
      end

      def compile_moves(expression, moves) = moves.inject(expression) { |sql, move| compile_move(sql, move) }

      def compile_converts(expression, converts) = converts.inject(expression) { |sql, convert| compile_convert(sql, convert) }

      def compile_drops(expression, drops) = drops.inject(expression) { |sql, name| compile_drop(sql, name) }

      def compile_computes(expression, computes) = computes.inject(expression) { |sql, compute| compile_compute(sql, compute) }

      def compile_backfills(expression, backfills)
        backfills.inject(expression) { |sql, backfill| compile_backfill(sql, backfill) }
      end

      # Wraps `expression` in the rename of one top-level key.
      def compile_rename(expression, old_name, new_name)
        "hecks_tr_rename(#{expression}, #{text_literal(old_name)}, #{text_literal(new_name)})"
      end

      # Wraps `expression` in the move of one path to another.
      def compile_move(expression, move)
        "hecks_tr_move(#{expression}, #{path_literal(move.from)}, #{path_literal(move.to)}, " \
          "#{text_literal("move #{move.from} to: #{move.to}")})"
      end

      # Wraps `expression` in the conversion of one path's value through a lookup table.
      def compile_convert(expression, convert)
        pairs = JSON.generate(convert.values.map { |key, value| [key, value] })
        "hecks_tr_convert(#{expression}, #{path_literal(convert.from)}, #{path_literal(convert.to)}, " \
          "#{text_literal(pairs)}::jsonb, #{text_literal(convert.from)}, " \
          "#{text_literal("convert #{convert.from} to: #{convert.to}")})"
      end

      # Wraps `expression` in the removal of one path.
      def compile_drop(expression, name)
        "hecks_tr_drop(#{expression}, #{path_literal(name)})"
      end

      # Reports whether an edge's declared rules for an aggregate include a rekey, read
      # directly off the raw IR like every other rule kind `compile_rules` checks.
      def rekeyed?(declared) = declared && !declared.rekeys.empty?

      # Builds a `CASE WHEN ... END AS aggregate_id` expression that only overrides
      # `aggregate_id` when `guard` matches, leaving the common no-rekey case untouched.
      def id_case(guard, declared)
        "CASE WHEN #{guard} THEN #{compile_id_expression(declared)} ELSE aggregate_id END AS aggregate_id"
      end

      # Evaluates a rekey's own SQL against the record's current `state`, read directly
      # rather than through `compile_rules`'s progressively-built expression chain.
      def compile_id_expression(declared)
        rekey = declared.rekeys.first
        "(SELECT (#{rekey.sql}) FROM (SELECT (state) AS __s) __outer)"
      end

      # Wraps `expression` so a compute's SQL result lands at its declared destination
      # when the source path is present; the whole record stays readable as `__s`.
      def compile_compute(expression, compute)
        from = compute.from.to_s
        to = compute.to.to_s
        "(SELECT CASE WHEN (__x).present THEN " \
          "hecks_tr_insert((__x).remaining, #{path_literal(to)}, to_jsonb((#{compute.sql})), " \
          "#{text_literal("compute #{from} to: #{to}")}) " \
          "ELSE __s END " \
          "FROM (SELECT (#{expression}) AS __s) __outer, " \
          "LATERAL (SELECT hecks_tr_extract(__s, #{path_literal(from)}) AS __x) __extract, " \
          "LATERAL (SELECT (__s #>> #{path_literal(from)}) AS #{quote(from)}) __fields)"
      end

      # Wraps `expression` so a backfill's default lands at its declared path only when
      # nothing is already there, the same rule `Lineage#translate`'s own pass holds to.
      def compile_backfill(expression, backfill)
        name = backfill.name.to_s
        default_json = JSON.generate(backfill.default)
        "(SELECT CASE WHEN (hecks_tr_extract(__s, #{path_literal(name)})).present THEN __s " \
          "ELSE hecks_tr_insert(__s, #{path_literal(name)}, #{text_literal(default_json)}::jsonb, " \
          "#{text_literal("backfill #{name}")}) END " \
          "FROM (SELECT (#{expression}) AS __s) __outer)"
      end

      # Quotes a Postgres identifier; requires "pg" lazily so a non-Postgres-bound
      # domain never gains a hard dependency on the gem just by loading this file.
      def quote(name)
        require "pg"
        PG::Connection.quote_ident(name.to_s)
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
