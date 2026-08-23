require "json"

module Hecksagain
  module Translation
    # The closed, PURE half of Postgres's own SQL compiler
    # (adapters/driven/postgres_era/lineage/head_compiler.rb) — the part
    # that turns one TranslationAggregate's declared rules into a
    # jsonb-transforming SQL expression. No database connection, no
    # watermark, no era chain, no catalog lookup: those stay exactly
    # where they were, in head_compiler.rb's own per-mint assembly,
    # which calls into this module instead of defining these methods
    # itself.
    #
    # Extracted here — not left as private methods on
    # Adapters::PostgresEra::Lineage — so a SECOND, adapter-agnostic
    # caller (Exporter.translation_aggregate's build-time SQL export,
    # feeding rust/host's own future boot-time mint) can call the exact
    # SAME code Ruby's own mint path runs, not a hand-ported duplicate
    # that could silently drift the way `Exporter.translation_hash`
    # drifted from `hecks_eras`/`hecks_approvals`' real schema before
    # this file existed (rekeys/backfills were missing for years).
    module RuleCompiler
      module_function

      # One edge's rules over one jsonb state, compiled as a nested
      # expression tree — hecks_tr_* helpers composed innermost-first
      # in the reference transform's phase order (renames, moves,
      # converts, drops), computes last. `retype` compiles to nothing:
      # stored state never carries a type name.
      def compile_rules(declared)
        expression = "state"
        declared.renames.each do |old_name, new_name|
          expression = "hecks_tr_rename(#{expression}, #{text_literal(old_name)}, #{text_literal(new_name)})"
        end
        declared.moves.each do |move|
          expression = "hecks_tr_move(#{expression}, #{path_literal(move.from)}, #{path_literal(move.to)}, " \
                       "#{text_literal("move #{move.from} to: #{move.to}")})"
        end
        declared.converts.each do |convert|
          pairs = JSON.generate(convert.values.map { |key, value| [key, value] })
          expression = "hecks_tr_convert(#{expression}, #{path_literal(convert.from)}, #{path_literal(convert.to)}, " \
                       "#{text_literal(pairs)}::jsonb, #{text_literal(convert.from)}, " \
                       "#{text_literal("convert #{convert.from} to: #{convert.to}")})"
        end
        declared.drops.each do |name|
          expression = "hecks_tr_drop(#{expression}, #{path_literal(name)})"
        end
        declared.computes.each do |compute|
          expression = compile_compute(expression, compute)
        end
        expression
      end

      # Whether THIS edge's declared rules for this aggregate include a
      # rekey — checked directly off the raw IR object, the same way
      # every other rule kind is already read in `compile_rules`
      # (`declared.computes`, `declared.moves`, ...), not through the
      # `Ports::Persistence::Lineage` wrapper the app-level consumers
      # (coverage_check.rb, minter.rb, layer_two.rb) go through — this
      # module builds SQL straight off the IR either way.
      def rekeyed?(declared) = declared && !declared.rekeys.empty?

      # THE ONLY TWO PLACES `aggregate_id` NEEDS TO CHANGE — guarded so
      # the generated SQL for the overwhelming common case (no rekey
      # declared) stays the bare `aggregate_id` passthrough it always
      # was — this CASE only appears in an edge that actually declares
      # one.
      def id_case(guard, declared)
        "CASE WHEN #{guard} THEN #{compile_id_expression(declared)} ELSE aggregate_id END AS aggregate_id"
      end

      # THE REKEY'S OWN SQL — reading `state` directly, not the
      # progressively-built `expression` chain `compile_compute` reads
      # from. A rekey doesn't consume or move any field the way a move
      # or compute does, so there is no same-edge rename/move ordering
      # it needs to see first — it reads the record's stored fields
      # exactly as they already are, the same `__s` convention
      # `compile_compute` exposes.
      def compile_id_expression(declared)
        rekey = declared.rekeys.first
        "(SELECT (#{rekey.sql}) FROM (SELECT (state) AS __s) __outer)"
      end

      # A compute is the one rule whose SQL is its only implementation
      # — evaluated exclusively inside the compiled head, never
      # in-process. The old field is exposed under its own name (as
      # text, exactly as the author's expression expects to cast it).
      def compile_compute(expression, compute)
        from = compute.from.to_s
        to = compute.to.to_s
        "(SELECT CASE WHEN __s ? #{text_literal(from)} THEN " \
          "hecks_tr_insert(__s - #{text_literal(from)}, #{path_literal(to)}, to_jsonb((#{compute.sql})), " \
          "#{text_literal("compute #{from} to: #{to}")}) " \
          "ELSE __s END " \
          "FROM (SELECT (#{expression}) AS __s) __outer, " \
          "LATERAL (SELECT (__s ->> #{text_literal(from)}) AS #{quote(from)}) __fields)"
      end

      # `PG::Connection.quote_ident` needs the `pg` gem LOADED, not
      # connected — required here, lazily, the same "a domain that
      # never wires PostgresEra should never need the gem" reasoning
      # `PostgresEra.connect_for`'s own `require "pg"` already holds
      # itself to, so a build tool that exports translations for a
      # non-Postgres-bound domain (there are none today, but nothing
      # here should assume there never will be) doesn't gain a hard
      # dependency on `pg` just by loading this file.
      def quote(name)
        require "pg"
        PG::Connection.quote_ident(name.to_s)
      end

      def text_literal(text) = "'#{text.to_s.gsub("'", "''")}'"

      def path_literal(path)
        segments = path.to_s.split(".").map { |segment| text_literal(segment) }
        "ARRAY[#{segments.join(', ')}]::text[]"
      end
    end
  end
end
