require_relative "../../../../naming"
require_relative "../../append_only"
require_relative "../../../../runtime/registry"
require_relative "lineage/rules"
require_relative "lineage/coverage"
require_relative "lineage/rewrite"

module Hecks
  module Ports
    module Persistence
      # Translates a journal entry written under an old shape into the one
      # the current bluebook declares; replay derives the head from unrewritten history.
      class Lineage
        include Coverage
        include Rewrite

        # `ancestor_name` is the declared name a rename came from (matches
        # the held bluebook's own aggregate names); `ancestor_storage_name`
        # is its derived, snake_case file/table name. Both are nil unless
        # the edge declares a `was:` name that differs from the aggregate's own.
        def ancestor_name = @rules.ancestor_name

        # @return [String, nil] the snake_case storage name of `ancestor_name`
        def ancestor_storage_name = @rules.ancestor_storage_name

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
              **optional_rules(declared), ancestor_name: ancestor_name, ancestor_storage_name: ancestor_storage_name)
        end

        # The rule lists an edge carries beyond renames, moves, converts and drops.
        def self.optional_rules(declared)
          { retypes: declared.retypes, derives: declared.derives,
            rekeys: declared.rekeys, backfills: declared.backfills }
        end
        private_class_method :optional_rules

        # @param renames [Hash{Symbol => Symbol}] old attribute name to new name
        # @param moves [Array<Bluebook::TranslationMove>] from/to paths across a value object
        # @param converts [Array<Bluebook::TranslationConvert>] moves mapped through a values table
        # @param drops [Array<Symbol>] bare or dotted paths whose data is discarded
        # @param rules [Hash] the optional rule lists, as `Rules` names them: `retypes:`,
        #   `derives:`, `rekeys:`, `backfills:`, `ancestor_name:` and
        #   `ancestor_storage_name:`
        # @raise [ArgumentError] on a keyword `Rules` does not name
        def initialize(renames, moves = [], converts = [], drops = [], **rules)
          @renames = renames
          @moves = moves
          @converts = converts
          @drops = drops
          @rules = Rules.build(**rules)
        end

        # Reports whether this edge rewrites the aggregate's identity.
        #
        # The single source of truth for this; other call sites ask here
        # rather than re-deriving it from `declared` themselves.
        #
        # @return [Boolean] true when the edge declares at least one rekey rule
        def rekey? = !@rules.rekeys.empty?

        # Rewrites one journal entry from the held shape into the current one.
        #
        # The reference semantics for derive, rename, move, convert, drop, `was:` and the id a
        # `rekey_to` takes.
        #
        # @param entry [Ports::Persistence::Entry] the entry as stored, with Symbol
        #   top-level keys and String keys nested in a value-object Hash
        # @return [Ports::Persistence::Entry] a new entry with translated state and the same
        #   `operation` and `mirrors`, and the same `id` unless a `rekey_to` gives it a value;
        #   `entry` itself when it is not a save or has no state
        # @raise [Runtime::WiringError] if a convert value is missing from its `values` table, or a
        #   move/convert would nest under a destination already holding a non-Hash value
        def translate(entry)
          return entry unless entry.save? && entry.state

          # Deep, not shallow: a move or convert reaches into a nested
          # value-object hash, and a shallow dup would quietly mutate
          # the caller's copy of the original entry.
          id = rekeyed_id(entry)
          state = rewrite(deep_dup(entry.state))
          Entry.new(operation: entry.operation, id: id, state: state, mirrors: entry.mirrors)
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
          @rules.retypes.any? { |retype| retype.from == held_type.to_s && retype.to == current_type.to_s }
        end
      end
    end
  end
end
