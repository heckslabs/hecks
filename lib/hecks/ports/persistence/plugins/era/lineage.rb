require_relative "../../../../naming"
require_relative "../../append_only"
require_relative "../../../../runtime/registry"

module Hecks
  module Ports
    module Persistence
      # Translates a journal entry written under an old shape into the one
      # the current bluebook declares — a renamed attribute, a renamed
      # aggregate, or a field crossing a value-object boundary. Applied
      # wherever entries are read, so replay derives the current head from
      # history that was never rewritten — the port owns the meaning,
      # adapters stay oblivious.
      class Lineage
        # `ancestor_name` is the declared name a rename came from (matches
        # the held bluebook's own aggregate names); `ancestor_storage_name`
        # is its derived, snake_case file/table name. Both are nil unless
        # the edge declares a `was:` name that differs from the aggregate's own.
        attr_reader :ancestor_name, :ancestor_storage_name

        # Builds the rules of the first declared translation that mentions an aggregate.
        #
        # @param registry [Runtime::Registry] the registry whose declared translations are
        #   searched, in declaration order
        # @param domain [String, Symbol] name of the domain the aggregate belongs to
        # @param aggregate [Bluebook::Aggregate] the aggregate as currently declared
        # @return [Ports::Persistence::Lineage, nil] the rules of the first translation for `domain`
        #   that names the aggregate; nil when none does
        def self.for(registry, domain, aggregate)
          translation = registry.translations.find do |candidate|
            candidate.domain == domain.to_s && candidate.for_aggregate(aggregate.name)
          end
          return nil unless translation

          from_declared(translation.for_aggregate(aggregate.name), aggregate.name)
        end

        # Builds the rules one declared translation edge carries for one aggregate.
        #
        # One specific edge's rules for one aggregate — what the mint
        # path uses, where `for` would happily answer with whichever
        # edge in the registry mentioned the aggregate first.
        #
        # @param declared [Bluebook::TranslationAggregate, nil] the edge's entry for the
        #   aggregate, as `Bluebook::Translation#for_aggregate` returns it; nil when the edge
        #   does not mention the aggregate
        # @param aggregate_name [String, Symbol] the aggregate's current name, compared with
        #   `declared.was` to decide whether the edge renames the aggregate itself
        # @return [Ports::Persistence::Lineage, nil] the edge's rules; nil when `declared` is nil
        def self.from_declared(declared, aggregate_name)
          return nil unless declared

          renamed_aggregate = declared.was && declared.was != aggregate_name.to_s
          ancestor_name = renamed_aggregate ? declared.was : nil
          ancestor_storage_name = renamed_aggregate ? Naming.snake(declared.was) : nil

          new(declared.renames, declared.moves, declared.converts, declared.drops,
              retypes: declared.retypes, computes: declared.computes, rekeys: declared.rekeys,
              backfills: declared.backfills,
              ancestor_name: ancestor_name, ancestor_storage_name: ancestor_storage_name)
        end

        # @param renames [Hash{Symbol => Symbol}] old top-level attribute name to new name
        # @param moves [Array<Bluebook::TranslationMove>] fields crossing a value-object
        #   boundary, each a `from`/`to` pair of bare or dotted paths
        # @param converts [Array<Bluebook::TranslationConvert>] moves whose value is replaced
        #   through an exhaustive `values` lookup table
        # @param drops [Array<Symbol>] bare or dotted paths whose data is deliberately discarded
        # @param retypes [Array<Bluebook::TranslationRetype>] value-object or entity type names
        #   declared to mean the same shape
        # @param computes [Array<Bluebook::TranslationCompute>] SQL-only rules, never applied
        #   in process
        # @param rekeys [Array<Bluebook::TranslationRekey>] SQL-only identity rewrites; only
        #   the first is read
        # @param backfills [Array<Bluebook::TranslationBackfill>] defaults for new top-level
        #   attributes an old entry lacks
        # @param ancestor_name [String, nil] the aggregate's declared name before the edge;
        #   nil unless the edge renames the aggregate itself
        # @param ancestor_storage_name [String, nil] snake_case storage name of
        #   `ancestor_name`; nil unless the edge renames the aggregate itself
        def initialize(renames, moves = [], converts = [], drops = [], retypes: [], computes: [], rekeys: [],
                       backfills: [], ancestor_name: nil, ancestor_storage_name: nil)
          @renames = renames
          @moves = moves
          @converts = converts
          @drops = drops
          @retypes = retypes
          @computes = computes
          @rekeys = rekeys
          @backfills = backfills
          @ancestor_name = ancestor_name
          @ancestor_storage_name = ancestor_storage_name
        end

        # Reports whether any rule in this edge is a compute.
        #
        # Compute is the one rule kind with no in-process implementation at
        # all. An aggregate carrying one refuses to boot anywhere but
        # Postgres, per-rule and by name, before the general drift
        # machinery says anything vaguer.
        #
        # @return [Boolean] true when the edge declares at least one compute rule
        def computes? = !@computes.empty?

        # Reports whether this edge rewrites the aggregate's identity.
        #
        # The single source of truth for "does this edge rekey this
        # aggregate" — every consumer (coverage_check.rb's identity gate,
        # minter.rb's approval gate, layer_two.rb's audit, head_compiler.rb's
        # SQL compilation) asks this, never re-derives it from `declared`
        # independently. One accessor to change if what a rekey rule means
        # ever needs to change, not four call sites in four files.
        #
        # @return [Boolean] true when the edge declares at least one rekey rule
        def rekey? = !@rekeys.empty?

        # Returns the SQL expression the edge's first rekey rule declares.
        #
        # The rekey's own SQL — first-and-only rule, same one-per-aggregate
        # assumption `compute` makes about its own list where it matters
        # (an edge with more than one is a DSL-level decision, not
        # something this reader arbitrates).
        #
        # @return [String, nil] the first rekey rule's SQL; nil when the edge declares no rekey
        def rekey_sql = @rekeys.first&.sql

        # Rewrites one journal entry's state from the held shape into the current one.
        #
        # The reference semantics for the five portable rule kinds —
        # rename, move, convert, drop, and the aggregate-level `was:`.
        # `retype` moves nothing (stored state never carries a type name)
        # and `compute` is deliberately not applied here: its SQL is its
        # only implementation, so this transform neither imitates nor
        # checks it — the source field passes through untouched, and the
        # audit verifies compute output against the matview alone.
        #
        # @param entry [Ports::Persistence::Entry] the entry as stored: `state` has Symbol
        #   top-level keys and String keys inside a nested value-object Hash
        # @return [Ports::Persistence::Entry] a new entry with a deep-copied, translated state
        #   and the same `operation`, `id` and `mirrors`; `entry` itself, untouched, when it
        #   is not a save or carries no state
        # @raise [Runtime::WiringError] if a convert meets a value missing from its `values`
        #   table, or a move or convert would nest under a destination already holding a
        #   non-Hash value
        def translate(entry)
          return entry unless entry.save? && entry.state

          # Deep, not shallow: a move or convert reaches into a nested
          # value-object hash, and a shallow dup would quietly mutate
          # the caller's copy of the original entry.
          state = deep_dup(entry.state)
          apply_renames(state, @renames)
          @moves.each { |move| apply_move(state, move) }
          @converts.each { |convert| apply_convert(state, convert) }
          @drops.each { |name| apply_drop(state, name) }
          # Last, and only where nothing already answered — a backfill
          # fills the gap a rename/move/convert left untouched, never
          # overwrites a value that already made it across.
          @backfills.each { |backfill| state[backfill.name] = backfill.default unless state.key?(backfill.name) }
          Entry.new(operation: entry.operation, id: entry.id, state: state, mirrors: entry.mirrors)
        end

        # Reports whether some rule accounts for a held path that vanished or changed type.
        #
        # Whether this translation names `path` as an old key it accounts
        # for — the rename, move, or convert it came from, or an explicit
        # drop. `path` is a bare name ("cost") or a dotted value-object
        # member ("price.currency"); a rule covering the whole top-level
        # attribute (a rename, a top-level move/convert/drop) also covers
        # anything nested under it, since the whole value travels or goes
        # away together. This is what catches a field — or a value object's
        # own member — that vanished (or silently changed type) without
        # anything explaining it, even when some other field is covered.
        #
        # `backfills` matches on the whole name only, never a dotted
        # prefix — a backfill names a top-level attribute that is new
        # outright (nothing to be a prefix of on the held side), unlike
        # every rule above it, which explains a path that existed and
        # moved, converted, or vanished.
        #
        # One `||` chain over a closed, fixed set of rule kinds (renames,
        # moves, converts, drops, computes, backfills) — the same six this
        # file's other methods enumerate. Splitting each disjunct into its
        # own predicate would scatter one question ("does any rule explain
        # this path") across six same-shaped methods with nothing else to
        # do.
        #
        # @param path [String, Symbol] a bare attribute name or a dotted value-object member
        #   path on the held side
        # @return [Boolean] true when a rename, move, convert, drop or compute names the path or
        #   its top-level attribute as its source, or a backfill names the top-level attribute
        # rubocop:disable-next Metrics/CyclomaticComplexity
        # rubocop:disable-next Metrics/PerceivedComplexity
        def explains?(path)
          path = path.to_s
          top = path.split(".").first

          @renames.key?(top.to_sym) ||
            @moves.any? { |move| move.from == path || move.from.split(".").first == top } ||
            @converts.any? { |convert| convert.from == path || convert.from.split(".").first == top } ||
            @drops.any? { |drop| drop.to_s == path || drop.to_s.split(".").first == top } ||
            @computes.any? { |compute| compute.from == path || compute.from.split(".").first == top } ||
            @backfills.any? { |backfill| backfill.name.to_s == top }
        end

        # Reports whether some rule gives an existing record a value at a new attribute.
        #
        # The destination-side twin of `explains?` above, which only ever
        # asks about a rule's source. `unsafe_additions` asks a different
        # question — not "was this vanished path accounted for" but "does
        # an existing record end up with a value here" — and a move or
        # convert whose `to:` lands a old field inside a brand-new
        # top-level attribute (`weight` becoming `contents.weight` when
        # `Contents` did not exist before) fills that attribute for an
        # existing record exactly as a `backfill` would, even though
        # nothing named `contents` explains any vanished path. `compute`
        # counts on the same terms `explains?` already grants it
        # elsewhere in this file — Postgres-only and audited, not
        # actually applied by this method, the same gap the vanish side
        # already lives with.
        #
        # `@renames.value?` belongs here too: a bare
        # `rename :cost, to: :amount` is the plainest possible covering
        # rule there is (`translate` above applies it unconditionally, no
        # lookup table, no per-record ambiguity — simpler than a move or
        # convert), and without it `unsafe_additions` reports the new name
        # as an unexplained required addition on every rename-only edge,
        # the single most common translation shape there is. `explains?`
        # checks the source side (`@renames.key?`); this is the symmetric
        # destination-side check.
        #
        # @param path [String, Symbol] the name of a top-level attribute new in the current
        #   shape
        # @return [Boolean] true when a rename, move, convert or compute lands a value in that
        #   attribute, or a backfill names it
        def fills?(path)
          path = path.to_s

          @renames.value?(path.to_sym) ||
            @moves.any? { |move| move.to.split(".").first == path } ||
            @converts.any? { |convert| convert.to.split(".").first == path } ||
            @computes.any? { |compute| compute.to.split(".").first == path } ||
            @backfills.any? { |backfill| backfill.name.to_s == path }
        end

        # Reports whether a declared retype pairs two type names as the same shape.
        #
        # A retype covers a value object or entity whose own name changed
        # with its members intact. Nothing in the stored data carries the
        # type name, so this never moves a value; it only satisfies the
        # era diff's literal type-name comparison.
        #
        # @param held_type [String, Bluebook::Reference] the type the held era declares,
        #   compared by its `to_s`
        # @param current_type [String, Bluebook::Reference] the type declared now, compared by
        #   its `to_s`
        # @return [Boolean] true when some retype rule runs from `held_type` to `current_type`
        def retype?(held_type, current_type)
          @retypes.any? { |retype| retype.from == held_type.to_s && retype.to == current_type.to_s }
        end

        private

        def deep_dup(node)
          case node
          when Hash then node.transform_values { |value| deep_dup(value) }
          when Array then node.map { |item| deep_dup(item) }
          else node
          end
        end

        # M27 (docs/audits/2026-08-10-main-bug-audit.md,
        # docs/audits/2026-08-11-bug-triage.md) — simultaneous, not
        # sequential: `state[new] = state.delete(old)` per rename, run
        # one rule at a time against the same hash it was reading from,
        # loses data the instant one rule's destination is another
        # rule's source. Applied sequentially, a swap (`rename :a, to: :b`
        # alongside `rename :b, to: :a`) on `{a: 1, b: 2}` produces
        # `{a: 1}` — the first rule writes `b: 1` over the real `b: 2`
        # before the second rule ever gets a chance to read it, and the
        # value the whole edge is supposed to preserve (2, moved to
        # `:a`) is gone. The standard fix: snapshot every rule's old
        # key and value from `state` first, then remove every old key
        # and only then write every new key — a rename never reads a
        # key this same pass has already written to, so a swap or a
        # longer chain applies as one permutation, not a sequence of
        # edits each stepping on the last.
        def apply_renames(state, renames)
          snapshot = renames.filter_map { |old_name, new_name| [old_name, new_name, state[old_name]] if state.key?(old_name) }
          snapshot.each { |old_name, _new_name, _value| state.delete(old_name) }
          # Not combinable (Style/CombinableLoops is disabled repo-wide, see
          # .rubocop.yml, for exactly this reason): a swap (:a<->:b) needs
          # every delete done before any write, or the first rename's write
          # becomes the second rename's delete target — see this method's
          # own comment above.
          snapshot.each { |_old_name, new_name, value| state[new_name] = value }
        end

        def apply_drop(state, name)
          name = name.to_s
          top, member = name.split(".", 2)
          top = top.to_sym

          if member
            nested = state[top]
            if nested.is_a?(Hash)
              nested.delete(member)
              state.delete(top) if nested.empty?
            end
          else
            state.delete(top)
          end
        end

        # A dotted path's first segment is a top-level (symbol) key; a
        # second segment reaches into a value-object member by its string
        # key — the spelling a raw stored row carries. Translation runs on
        # raw rows, before the state codec decodes anything (PR A3): its
        # only caller (`Translation::Audit::LayerTwo`) feeds it
        # head-snapshot rows straight out of `JSON.parse`, and the
        # PostgresEra head applies the same rules in SQL before
        # `PostgresEra#decode` ever sees the jsonb. Decode is always the
        # last step, so an undeclared (retired) member this rule has to
        # read is still exactly as it was written, and never something an
        # adapter's `entries` — decoded, deep-symbol — would be fed here.
        def apply_move(state, move)
          old_top, old_member = move.from.split(".", 2)
          new_top, new_member = move.to.split(".", 2)
          old_top = old_top.to_sym

          value, present = extract(state, old_top, old_member)
          return unless present

          insert(state, new_top.to_sym, new_member, value, rule: "move #{move.from} to: #{move.to}")
        end

        # A convert is a move whose value has nothing in common with its
        # replacement — the same path machinery, plus a lookup. A value
        # with no entry in the table refuses loudly rather than carry an
        # unrecognized value silently into the new era.
        def apply_convert(state, convert)
          old_top, old_member = convert.from.split(".", 2)
          new_top, new_member = convert.to.split(".", 2)
          old_top = old_top.to_sym

          raw, present = extract(state, old_top, old_member)
          return unless present

          unless convert.values.key?(raw)
            raise Runtime::WiringError,
                  "cannot translate #{convert.from}: #{raw.inspect} has no mapping in its " \
                  "convert's values: table. Add #{raw.inspect} => ... to cover it."
          end

          insert(state, new_top.to_sym, new_member, convert.values[raw], rule: "convert #{convert.from} to: #{convert.to}")
        end

        def extract(state, top, member)
          return [nil, false] unless state.key?(top)
          return [state.delete(top), true] unless member

          nested = state[top]
          return [nil, false] unless nested.is_a?(Hash) && nested.key?(member)

          value = nested.delete(member)
          state.delete(top) if nested.empty?
          [value, true]
        end

        # Adversarial finding, not a hypothetical: a destination whose
        # top segment already holds a value — most commonly a reference,
        # stored as a bare scalar id — must not be nested under when a
        # dotted destination needs it (`state[top] ||= {}` alone only
        # guards nil/false, so a truthy non-Hash sails straight through
        # to `state[top][member] =`, i.e. `"team-1"["detail"] =`, which
        # is String#[]=  and raises an unrelated-looking IndexError).
        # Whether it crashes or silently replaces the value, that is a
        # `drop` that never declared itself — the one thing this language
        # exists to make explicit (see apply_convert's own refusal above,
        # the same shape). Refuse by name instead, on both sides: the SQL
        # half (hecks_tr_insert) raises the identical wording.
        def insert(state, top, member, value, rule:)
          return state[top] = value unless member

          if state.key?(top) && !state[top].is_a?(Hash)
            raise Runtime::WiringError,
                  "cannot #{rule}: #{top} already holds #{state[top].inspect}, not a value this can nest " \
                  "under — moving into it would discard that value silently. Rename or drop #{top} first."
          end

          state[top] ||= {}
          state[top][member] = value
        end
      end
    end
  end
end
