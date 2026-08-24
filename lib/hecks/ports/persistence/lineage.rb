require_relative "../../naming"
require_relative "append_only"
require_relative "../../runtime/registry"

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
        # the aggregate itself was renamed.
        attr_reader :ancestor_name, :ancestor_storage_name

        def self.for(registry, domain, aggregate)
          translation = registry.translations.find do |candidate|
            candidate.domain == domain.to_s && candidate.for_aggregate(aggregate.name)
          end
          return nil unless translation

          from_declared(translation.for_aggregate(aggregate.name), aggregate.name)
        end

        # One SPECIFIC edge's rules for one aggregate — what the mint
        # path uses, where `for` would happily answer with whichever
        # edge in the registry mentioned the aggregate first.
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

        # Whether any rule in this edge is a compute — the one rule kind
        # with no in-process implementation at all. An aggregate carrying
        # one refuses to boot anywhere but Postgres, per-rule and by name,
        # before the general drift machinery says anything vaguer.
        def computes? = !@computes.empty?

        # THE SINGLE SOURCE OF TRUTH for "does this edge rekey this
        # aggregate" — every consumer (coverage_check.rb's identity gate,
        # minter.rb's approval gate, layer_two.rb's audit, head_compiler.rb's
        # SQL compilation) asks THIS, never re-derives it from `declared`
        # independently. One accessor to change if what a rekey rule means
        # ever needs to change, not four call sites in four files.
        def rekey? = !@rekeys.empty?

        # The rekey's own SQL — first-and-only rule, same one-per-aggregate
        # assumption `compute` makes about its own list where it matters
        # (an edge with more than one is a DSL-level decision, not
        # something this reader arbitrates).
        def rekey_sql = @rekeys.first&.sql

        # The reference semantics for the five PORTABLE rule kinds —
        # rename, move, convert, drop, and the aggregate-level `was:`.
        # `retype` moves nothing (stored state never carries a type name)
        # and `compute` is deliberately not applied here: its SQL is its
        # only implementation, so this transform neither imitates nor
        # checks it — the source field passes through untouched, and the
        # audit verifies compute output against the matview alone.
        def translate(entry)
          return entry unless entry.save? && entry.state

          # Deep, not shallow: a move or convert reaches INTO a nested
          # value-object hash, and a shallow dup would quietly mutate
          # the caller's copy of the original entry.
          state = deep_dup(entry.state)
          @renames.each { |old_name, new_name| state[new_name] = state.delete(old_name) if state.key?(old_name) }
          @moves.each { |move| apply_move(state, move) }
          @converts.each { |convert| apply_convert(state, convert) }
          @drops.each { |name| apply_drop(state, name) }
          # LAST, and only where nothing already answered — a backfill
          # fills the gap a rename/move/convert left untouched, never
          # overwrites a value that already made it across.
          @backfills.each { |backfill| state[backfill.name] = backfill.default unless state.key?(backfill.name) }
          Entry.new(operation: entry.operation, id: entry.id, state: state, mirrors: entry.mirrors)
        end

        # Whether this translation names `path` as an old key it accounts
        # for — the rename, move, or convert it came from, or an explicit
        # drop. `path` is a bare name ("cost") or a dotted value-object
        # member ("price.currency"); a rule covering the WHOLE top-level
        # attribute (a rename, a top-level move/convert/drop) also covers
        # anything nested under it, since the whole value travels or goes
        # away together. Used to catch a field — or a value object's own
        # member — that vanished (or silently changed type) without
        # anything explaining it, even when some OTHER field is covered.
        #
        # `backfills` matches on the WHOLE name only, never a dotted
        # prefix — a backfill names a top-level attribute that is new
        # outright (nothing to be a prefix of on the held side), unlike
        # every rule above it, which explains a path that existed and
        # moved, converted, or vanished.
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

        # THE DESTINATION-SIDE TWIN of `explains?` above, which only ever
        # asks about a rule's SOURCE. `unsafe_additions` asks a different
        # question — not "was this vanished path accounted for" but "does
        # an existing record end up with a value here" — and a move or
        # convert whose `to:` lands a old field inside a BRAND-NEW
        # top-level attribute (`weight` becoming `contents.weight` when
        # `Contents` did not exist before) fills that attribute for an
        # existing record exactly as a `backfill` would, even though
        # nothing named `contents` explains any vanished path. `compute`
        # counts on the same terms `explains?` already grants it
        # elsewhere in this file — Postgres-only and audited, not
        # actually applied by THIS method, the same gap the vanish side
        # already lives with.
        #
        # `@renames.value?` belongs here too, and used to be missing: a
        # bare `rename :cost, to: :amount` is the plainest possible
        # covering rule there is (`translate` above applies it
        # unconditionally, no lookup table, no per-record ambiguity —
        # simpler than a move or convert, which both got their `fills?`
        # entry from the start), and its absence meant `unsafe_additions`
        # reported the new name as an unexplained required addition on
        # EVERY rename-only edge, the single most common translation
        # shape there is. `explains?` already checked the source side
        # (`@renames.key?`); `fills?` is the symmetric destination-side
        # check that was never added alongside it.
        def fills?(path)
          path = path.to_s

          @renames.value?(path.to_sym) ||
            @moves.any? { |move| move.to.split(".").first == path } ||
            @converts.any? { |convert| convert.to.split(".").first == path } ||
            @computes.any? { |compute| compute.to.split(".").first == path } ||
            @backfills.any? { |backfill| backfill.name.to_s == path }
        end

        # Whether a declared retype says the pair of TYPE names means the
        # same shape — a value object or entity whose own name changed
        # with its members intact. Nothing in the stored data carries the
        # type name, so this never moves a value; it only satisfies the
        # era diff's literal type-name comparison.
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
        # second segment reaches into a value-object member, stored with a
        # string key exactly as the adapter's own journal reader loaded it.
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

        # ADVERSARIAL FINDING, not a hypothetical: a destination whose
        # top segment ALREADY holds a value — most commonly a reference,
        # stored as a bare scalar id — used to be silently clobbered with
        # an empty hash the moment a dotted destination needed to nest
        # under it (`state[top] ||= {}` only guards nil/false, so a
        # truthy non-Hash sailed straight through to `state[top][member] =`,
        # i.e. `"team-1"["detail"] =`, which is String#[]=  and raised an
        # unrelated-looking IndexError). Whether it crashed or silently
        # replaced the value, this is a `drop` that never declared
        # itself — the one thing this language exists to make explicit
        # (see apply_convert's own refusal above, the same shape). Refuse
        # by name instead, on both sides: the SQL half (hecks_tr_insert)
        # raises the identical wording.
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
