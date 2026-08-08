module Hecksagain
  module Bluebook
    module IR
      # One field crossing a value-object boundary: a scalar becoming a VO
      # member, a VO member becoming a scalar, or a rename across the move.
      # Paths are dotted ("price.cents") for a VO member, bare otherwise.
      TranslationMove = Struct.new(:from, :to)

      # One field whose VALUE, not just its name or position, changed —
      # an old value has nothing in common with a new one, so the only
      # honest way to bridge it is a declared, exhaustive lookup table.
      # Paths follow `TranslationMove`'s convention (dotted reaches a VO
      # member); `values` maps every old-era value that can appear to its
      # new-era replacement.
      TranslationConvert = Struct.new(:from, :to, :values)

      # A value object's or entity's own TYPE NAME changed with its member
      # structure unchanged — the one drift `rename`/`move` cannot express,
      # because the attribute kept its name and only the type it points at
      # was renamed. Mirrors `was:` one level deeper.
      TranslationRetype = Struct.new(:from, :to)

      # A computed transform — rescale, reformat, split, merge — whose only
      # implementation is the SQL expression itself, evaluated exclusively
      # inside the compiled Postgres head. No in-process reference exists
      # to check it against; any aggregate carrying one refuses to boot on
      # every other adapter.
      TranslationCompute = Struct.new(:from, :to, :sql)

      # The aggregate's own IDENTITY changed what it's computed from — not
      # a field crossing a boundary (that's `move`), a value objects's type
      # name (`retype`), or a value transform (`compute`): the record's own
      # key. No `from:`/`to:` path, unlike every other rule here, because
      # nothing is being consumed from or moved into `state` — the state
      # a record already holds is untouched; only what identifies it is
      # recomputed. Same SQL-only, Postgres-only, no-in-process-reference
      # shape `compute` already has, and for the same reason: there is
      # nothing to check this against outside the compiled head.
      TranslationRekey = Struct.new(:sql)

      # One aggregate's part of a translation: which attributes were
      # renamed, moved, converted, or deliberately dropped on the way from
      # the old era to the new one. `drops` exists so data loss is a
      # declared decision, not a field that quietly stopped being
      # explained.
      class TranslationAggregate
        attr_reader :name, :was, :renames, :moves, :converts, :drops, :retypes, :computes, :rekeys

        def initialize(name:, was: nil, renames: {}, moves: [], converts: [], drops: [], retypes: [],
                        computes: [], rekeys: [])
          @name     = name.to_s
          @was      = was&.to_s
          @renames  = renames
          @moves    = moves
          @converts = converts
          @drops    = drops
          @retypes  = retypes
          @computes = computes
          @rekeys   = rekeys
        end
      end

      # A declared map from one era of a domain's storage shape to the
      # next. Renames and moves — the smallest slice that proves the
      # concept: old records are translated when they are replayed, never
      # rewritten. `retired` acknowledges aggregates that are gone
      # outright — not renamed — so their disappearance is a decision,
      # not an accident.
      class Translation
        attr_reader :domain, :from, :to, :aggregates, :retired

        def initialize(domain:, from:, to:, aggregates: [], retired: [])
          @domain     = domain.to_s
          @from       = from
          @to         = to
          @aggregates = aggregates
          @retired    = retired
        end

        def for_aggregate(name) = @aggregates.find { |aggregate| aggregate.name == name.to_s }
      end
    end
  end
end
