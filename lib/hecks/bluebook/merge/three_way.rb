require_relative "block"
require_relative "conflict"

module Hecks
  module Bluebook
    module Merge
      # Merges a member the base and two branches each hold a version of. A change on one branch
      # is taken, the same change on both is taken once, and a block both branches changed is
      # merged member by member; what cannot be settled is recorded as a {Conflict}.
      class ThreeWay
        # @return [Array<Conflict>] every disagreement found, in the order met
        attr_reader :conflicts

        def initialize
          @conflicts = []
        end

        # @param trio [Trio] the member on the base and on each branch; nil where it is absent
        # @param owners [Array<Array(String, String)>] the declarations around it, outermost first
        # @return [Member, nil] the merged member, or nil when it is removed
        def settle(trio, owners)
          return added(trio, owners) unless trio.base
          return removed(trio, owners) unless trio.ours && trio.theirs

          taken = pick(trio.texts)
          taken ? trio[taken] : both_changed(trio, owners)
        end

        private

        # Which of three versions stands when at most one branch changed it, or both changed it
        # alike: 1 for ours, 2 for theirs, nil when the branches disagree.
        def pick(versions)
          base, ours, theirs = versions
          return 2 if ours == base

          1 if [base, ours].include?(theirs)
        end

        def added(trio, owners)
          _, ours, theirs = trio.texts
          return trio.ours || trio.theirs unless ours && theirs
          return trio.ours if ours == theirs

          conflict(:both_added, trio, owners)
        end

        def removed(trio, owners)
          base, ours, theirs = trio.texts
          return nil if [nil, base].include?(ours || theirs)

          conflict(:removed_and_changed, trio, owners)
        end

        def both_changed(trio, owners)
          return conflict(:both_changed, trio, owners) unless trio.blocks?

          ours = trio.ours
          inside = ours.word == "file" ? owners : owners + [ours.label]
          block = Block.new(trio)
          block.rivals.each { |pair| conflict(:both_added, pair, inside) }
          rebuilt(trio, block.trios.filter_map { |member| settle(member, inside) }, owners)
        end

        def rebuilt(trio, children, owners)
          merged = trio.ours.dup
          %i[head tail foot].each { |part| merged[part] = part_of(part, trio, owners) }
          merged.children = children
          merged
        end

        # The text around a block's members (its opening, closing and trailing lines), merged
        # as one value each.
        def part_of(part, trio, owners)
          versions = trio.map { |member| member[part] }
          taken = pick(versions)
          conflict(:both_changed, trio, owners) unless taken
          versions[taken || 1]
        end

        def conflict(kind, trio, owners)
          shown = trio.ours || trio.theirs || trio.base
          texts = %i[base ours theirs].zip(trio.texts).to_h
          @conflicts << Conflict.new(kind: kind, owners: owners, **shown.to_h.slice(:word, :name, :named), **texts)
          shown
        end
      end
    end
  end
end
