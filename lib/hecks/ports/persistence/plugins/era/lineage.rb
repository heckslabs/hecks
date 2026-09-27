require_relative "../../../../naming"
require_relative "../../append_only"
require_relative "../../../../runtime/registry"

module Hecks
  module Ports
    module Persistence
      # Translates a journal entry written under an old shape into the one
      # the current bluebook declares; replay derives the head from unrewritten history.
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
        # @return [Ports::Persistence::Lineage, nil] the first translation for `domain` naming
        #   the aggregate; nil when none does
        def self.for(registry, domain, aggregate)
          translation = registry.translations.find do |candidate|
            candidate.domain == domain.to_s && candidate.for_aggregate(aggregate.name)
          end
          return nil unless translation

          from_declared(translation.for_aggregate(aggregate.name), aggregate.name)
        end

        # Builds the rules one declared translation edge carries for one aggregate.
        #
        # Unlike `for`, this uses one specific edge, not whichever edge in
        # the registry mentions the aggregate first — what the mint path needs.
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

        # @param renames [Hash{Symbol => Symbol}] old attribute name to new name
        # @param moves [Array<Bluebook::TranslationMove>] from/to paths across a value object
        # @param converts [Array<Bluebook::TranslationConvert>] moves mapped through a values table
        # @param drops [Array<Symbol>] bare or dotted paths whose data is discarded
        # @param retypes [Array<Bluebook::TranslationRetype>] type names meaning the same shape
        # @param computes [Array<Bluebook::TranslationCompute>] SQL-only rules, never applied here
        # @param rekeys [Array<Bluebook::TranslationRekey>] SQL rewrites; only the first is read
        # @param backfills [Array<Bluebook::TranslationBackfill>] defaults for a new attribute
        # @param ancestor_name [String, nil] the aggregate's name before the edge, if renamed
        # @param ancestor_storage_name [String, nil] snake_case storage name of ancestor_name
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
        # Compute has no in-process implementation; an aggregate carrying
        # one refuses to boot anywhere but Postgres.
        #
        # @return [Boolean] true when the edge declares at least one compute rule
        def computes? = !@computes.empty?

        # Reports whether this edge rewrites the aggregate's identity.
        #
        # The single source of truth for this; other call sites ask here
        # rather than re-deriving it from `declared` themselves.
        #
        # @return [Boolean] true when the edge declares at least one rekey rule
        def rekey? = !@rekeys.empty?

        # Returns the SQL expression the edge's first rekey rule declares.
        #
        # Only the first rule is read, the same one-per-aggregate assumption
        # `compute` makes; more than one is a DSL-level decision to arbitrate elsewhere.
        #
        # @return [String, nil] the first rekey rule's SQL; nil when the edge declares no rekey
        def rekey_sql = @rekeys.first&.sql

        # Rewrites one journal entry's state from the held shape into the current one.
        #
        # The reference semantics for rename, move, convert, drop, and the aggregate-level `was:`.
        # `compute` is not applied here — its SQL is the only implementation, audited separately.
        #
        # @param entry [Ports::Persistence::Entry] the entry as stored, with Symbol
        #   top-level keys and String keys nested in a value-object Hash
        # @return [Ports::Persistence::Entry] a new entry with translated state and the same
        #   `operation`, `id` and `mirrors`; `entry` itself when it is not a save or has no state
        # @raise [Runtime::WiringError] if a convert value is missing from its `values` table, or a
        #   move/convert would nest under a destination already holding a non-Hash value
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
          # Only fills a gap nothing else already filled; dotted-path aware, like apply_drop.
          @backfills.each { |backfill| apply_backfill(state, backfill) }
          Entry.new(operation: entry.operation, id: entry.id, state: state, mirrors: entry.mirrors)
        end

        # Reports whether some rule accounts for a held path that vanished or changed type.
        #
        # A rule covering a whole top-level attribute also covers anything nested
        # under it; `backfills` only matches a whole name, since a backfill adds an
        # attribute that is new outright, never a path that existed and moved.
        #
        # @param path [String, Symbol] a bare attribute name or a dotted value-object member path
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
        # The destination-side twin of `explains?`, which checks a rule's source; this checks
        # `@renames.value?` too, since a bare rename fills the destination unconditionally,
        # the same way a backfill would.
        #
        # @param path [String, Symbol] the name of a top-level attribute new in the current shape
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
        # Nothing in the stored data carries a type name, so this never moves a value;
        # it only satisfies the era diff's literal type-name comparison.
        #
        # @param held_type [String, Bluebook::Reference] the type the held era declares
        # @param current_type [String, Bluebook::Reference] the type declared now
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

        # Snapshots every rename's old key/value before writing any new key, so a
        # swap (:a<->:b) applies as one permutation instead of losing data when one
        # rule's destination is another's source.
        def apply_renames(state, renames)
          snapshot = renames.filter_map { |old_name, new_name| [old_name, new_name, state[old_name]] if state.key?(old_name) }
          snapshot.each { |old_name, _new_name, _value| state.delete(old_name) }
          # Not combinable: every delete must finish before any write, or a swap's
          # first write becomes its second delete target.
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

        # Dotted-path aware; must stay in step with `hecks_tr_insert` in rule_compiler.rb.
        def apply_backfill(state, backfill)
          name = backfill.name.to_s
          top, member = name.split(".", 2)
          top = top.to_sym

          if member
            nested = (state[top] ||= {})
            nested[member] = backfill.default unless nested.key?(member)
          else
            state[top] = backfill.default unless state.key?(top)
          end
        end

        # Runs on raw rows, before the state codec decodes anything — decode is
        # always the last step, so this never sees an adapter's deep-symbolized entry.
        def apply_move(state, move)
          old_top, old_member = move.from.split(".", 2)
          new_top, new_member = move.to.split(".", 2)
          old_top = old_top.to_sym

          value, present = extract(state, old_top, old_member)
          return unless present

          insert(state, new_top.to_sym, new_member, value, rule: "move #{move.from} to: #{move.to}")
        end

        # A convert is a move whose value has nothing in common with its replacement.
        # A value missing from the lookup table refuses loudly rather than carry an
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

        # A destination already holding a non-Hash value (e.g. a bare reference id)
        # must not be silently nested under — that would be an undeclared drop. The
        # SQL half (`hecks_tr_insert`) refuses with identical wording.
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
