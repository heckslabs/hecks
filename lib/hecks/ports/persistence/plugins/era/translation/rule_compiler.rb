require "json"

module Hecks
  module Translation
    # The closed, pure half of Postgres's own SQL compiler
    # (ports/persistence/plugins/era/postgres_era/lineage/head_compiler.rb)
    # — the part that turns one TranslationAggregate's declared rules into
    # a jsonb-transforming SQL expression. No database connection, no
    # watermark, no era chain, no catalog lookup: those live in
    # head_compiler.rb's own per-mint assembly, which calls into this
    # module instead of defining these methods itself.
    #
    # A module of its own — not private methods on
    # Adapters::PostgresEra::Lineage — so a second, adapter-agnostic
    # caller (Exporter.translation_aggregate's build-time SQL export,
    # feeding rust/host's own future boot-time mint) can call the exact
    # same code Ruby's own mint path runs, not a hand-ported duplicate
    # that could silently drift the way a hand-kept
    # `Exporter.translation_hash` can drift from `hecks_eras`/
    # `hecks_approvals`' real schema (leaving out rekeys and backfills).
    module RuleCompiler
      module_function

      # One edge's rules over one jsonb state, compiled as a nested
      # expression tree — hecks_tr_* helpers composed innermost-first
      # in the reference transform's phase order (renames, moves,
      # converts, drops), computes last. `retype` compiles to nothing:
      # stored state never carries a type name.
      # Compiles a declared edge's rename/move/convert/drop/compute rules into one nested SQL
      # expression over the `state` jsonb column.
      #
      # @param declared [Bluebook::TranslationAggregate] this edge's declared rules for one
      #   aggregate
      # @return [String] a SQL expression, `"state"` unchanged when `declared` declares none
      #   of the five rule kinds
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
        # Backfills last, same order `Lineage#translate` already applies
        # in-process (that method's own comment: "only where nothing
        # already answered") — now compiled here too, closing the gap
        # this rule kind otherwise leaves: `rust/host`'s boot-time mint
        # audit reads this exact compiled expression, never
        # `Lineage#translate`, so it cannot see a backfilled value unless
        # backfills compile to SQL like every other rule kind here. A
        # real, live gap for any new required value-object member with no
        # source data at all — `compute` cannot fill it either, since its
        # own guard requires a real, already-present field to consume
        # (found live: lifeadelics' Attendee redesign, commit 4326dcd,
        # needed exactly this and had nothing that worked).
        declared.backfills.each do |backfill|
          expression = compile_backfill(expression, backfill)
        end
        expression
      end

      # Whether this edge's declared rules for this aggregate include a
      # rekey — checked directly off the raw IR object, the same way
      # every other rule kind is already read in `compile_rules`
      # (`declared.computes`, `declared.moves`, ...), not through the
      # `Ports::Persistence::Lineage` wrapper the app-level consumers
      # (coverage_check.rb, minter.rb, layer_two.rb) go through — this
      # module builds SQL straight off the IR either way.
      # Reports whether an edge's declared rules for an aggregate include a rekey.
      #
      # @param declared [Bluebook::TranslationAggregate, nil] this edge's declared rules for
      #   one aggregate; nil for an aggregate the edge declares nothing about
      # @return [Boolean] true when `declared` is present and its `rekeys` is non-empty
      def rekeyed?(declared) = declared && !declared.rekeys.empty?

      # The only two places `aggregate_id` needs to change — guarded so
      # the generated SQL for the overwhelming common case (no rekey
      # declared) stays the bare `aggregate_id` passthrough it always
      # was — this case only appears in an edge that actually declares
      # one.
      #
      # @param guard [String] a SQL boolean expression gating when the rekey applies, such as
      #   `"operation = 'save'"`
      # @param declared [Bluebook::TranslationAggregate] this edge's declared rules; must
      #   declare a rekey (`rekeyed?(declared)` true)
      # @return [String] a `"CASE WHEN ... END AS aggregate_id"` SQL expression
      def id_case(guard, declared)
        "CASE WHEN #{guard} THEN #{compile_id_expression(declared)} ELSE aggregate_id END AS aggregate_id"
      end

      # The rekey's own SQL — reading `state` directly, not the
      # progressively-built `expression` chain `compile_compute` reads
      # from. A rekey doesn't consume or move any field the way a move
      # or compute does, so there is no same-edge rename/move ordering
      # it needs to see first — it reads the record's stored fields
      # exactly as they already are, the same `__s` convention
      # `compile_compute` exposes.
      #
      # @param declared [Bluebook::TranslationAggregate] this edge's declared rules; its
      #   first `rekeys` entry supplies the SQL
      # @return [String] a SQL expression evaluating the rekey's own SQL against the record's
      #   current `state`
      def compile_id_expression(declared)
        rekey = declared.rekeys.first
        "(SELECT (#{rekey.sql}) FROM (SELECT (state) AS __s) __outer)"
      end

      # A compute is the one rule whose SQL is its only implementation
      # — evaluated exclusively inside the compiled head, never
      # in-process. The old field is exposed under its own name (as
      # text, exactly as the author's expression expects to cast it).
      #
      # @param expression [String] the SQL expression built so far by `compile_rules`, read as
      #   `__s` inside the compute's own SQL
      # @param compute [Bluebook::TranslationCompute] the declared compute rule
      # @return [String] `expression` wrapped so the compute's field lands at its declared
      #   destination when the source field is present, unchanged otherwise
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

      # A newly added, required attribute with no source at all — the
      # addition-side sibling of `compile_compute`'s own header, but with
      # no field to consume: `hecks_tr_extract`'s own `.present` flag
      # (already installed for `hecks_tr_drop`/`hecks_tr_move`/
      # `hecks_tr_convert` — no new database function needed) answers
      # "is this path — bare or a dotted value-object member alike —
      # already there," and `hecks_tr_insert` (already merge-safe: it
      # creates a missing intermediate container without disturbing any
      # sibling member already in it) fills it only when it is not, the
      # exact "never overwrites a value already there" rule `Lineage#
      # translate`'s own in-process backfill already holds itself to.
      #
      # @param expression [String] the SQL expression built so far by `compile_rules`, read as
      #   `__s` inside this backfill's own check
      # @param backfill [Bluebook::TranslationBackfill] the declared backfill rule
      # @return [String] `expression` wrapped so the backfill's default lands at its declared
      #   path when nothing is there yet, unchanged otherwise
      def compile_backfill(expression, backfill)
        name = backfill.name.to_s
        default_json = JSON.generate(backfill.default)
        "(SELECT CASE WHEN (hecks_tr_extract(__s, #{path_literal(name)})).present THEN __s " \
          "ELSE hecks_tr_insert(__s, #{path_literal(name)}, #{text_literal(default_json)}::jsonb, " \
          "#{text_literal("backfill #{name}")}) END " \
          "FROM (SELECT (#{expression}) AS __s) __outer)"
      end

      # `PG::Connection.quote_ident` needs the `pg` gem loaded, not
      # connected — required here, lazily, the same "a domain that
      # never wires PostgresEra should never need the gem" reasoning
      # `PostgresEra.connect_for`'s own `require "pg"` already holds
      # itself to, so a build tool that exports translations for a
      # non-Postgres-bound domain (there are none today, but nothing
      # here should assume there never will be) doesn't gain a hard
      # dependency on `pg` just by loading this file.
      #
      # @param name [String, Symbol] the identifier to quote
      # @return [String] `name` as a double-quoted Postgres identifier
      def quote(name)
        require "pg"
        PG::Connection.quote_ident(name.to_s)
      end

      # Renders a Ruby value as a single-quoted SQL text literal, escaping embedded quotes.
      #
      # @param text [String, Symbol, Object] the value to render; converted with `to_s`
      # @return [String] a single-quoted SQL literal
      def text_literal(text) = "'#{text.to_s.gsub("'", "''")}'"

      # Renders a dotted path as a SQL `text[]` array literal, one element per segment.
      #
      # @param path [String, Symbol] a bare or dotted path, such as `"price.cents"`
      # @return [String] a SQL `ARRAY[...]::text[]` expression
      def path_literal(path)
        segments = path.to_s.split(".").map { |segment| text_literal(segment) }
        "ARRAY[#{segments.join(', ')}]::text[]"
      end
    end
  end
end
