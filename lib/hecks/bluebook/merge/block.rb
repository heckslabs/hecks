require_relative "alignment"

module Hecks
  module Bluebook
    module Merge
      # One member, or one block's members by key, as the base and each branch hold it.
      Trio = Struct.new(:base, :ours, :theirs) do
        # @return [Array<String, nil>] each version's text; nil where the member is absent
        def texts = map { |member| member&.text }

        # @return [Boolean] whether every version is a block with members of its own
        def blocks? = all? { |member| member&.children }
      end

      # The members of one block on the base and on each branch, matched up by key.
      class Block
        # Nameless words a block may hold several of, so each branch adding one is no conflict.
        REPEATED = %w[invariant given ensures].freeze

        # @param trio [Trio] the block on the base and on each branch, each with children
        def initialize(trio)
          base, ours, theirs = trio.map(&:children)
          alignment = Alignment.new(base)
          @keyed = Trio.new(alignment.base, alignment.keyed(ours), alignment.keyed(theirs))
        end

        # @return [Array<Trio>] each member's three versions, in the order the merged block reads
        def trios = order.map { |key| Trio.new(*@keyed.map { |side| side[key] }) }

        # A nameless word the base block lacks and each branch gives a different value (`goal`,
        # `persisted_by`) may be one a block holds once, so the pair is reported, not kept as two.
        #
        # @return [Array<Trio>] each such pair, with no base
        def rivals
          base, ours, theirs = @keyed.map { |side| side.values.reject(&:named).group_by(&:word) }
          ((ours.keys & theirs.keys) - base.keys - REPEATED).filter_map { |word| rival(ours[word], theirs[word]) }
        end

        private

        def rival(ours, theirs)
          Trio.new(nil, ours.first, theirs.first) if ours.map(&:text) != theirs.map(&:text)
        end

        # Ours, with each member only theirs holds put after the member that precedes it there.
        def order
          keys = @keyed.ours.keys
          previous = nil
          @keyed.theirs.each_key do |key|
            keys.insert(previous ? keys.index(previous) + 1 : 0, key) unless keys.include?(key)
            previous = key
          end
          keys | @keyed.base.keys
        end
      end
    end
  end
end
