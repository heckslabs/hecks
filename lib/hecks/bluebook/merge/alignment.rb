module Hecks
  module Bluebook
    module Merge
      # Gives the members of one block a key each, so the same member is found on the base and on
      # both branches. A base member's key is its group and its place in it. A branch's member
      # takes the key of the base member it is: the one with the same text, or failing that the
      # one standing in the same gap between members that did not change, which makes an edit of
      # a nameless member (`role`, an `invariant`) one member changed and not one removed and
      # one added. A member the base lacks gets a key of its own.
      class Alignment
        # @return [Hash{Array => Member}] the base members by key, in the order written
        attr_reader :base

        # @param members [Array<Member>] the base block's members
        def initialize(members)
          @groups = members.group_by(&:group)
          @base = @groups.flat_map { |group, found| found.each_with_index.map { |member, at| [[group, at], member] } }.to_h
        end

        # @param members [Array<Member>] one branch's members of the same block
        # @return [Hash{Array => Member}] them by key, in the order written
        def keyed(members)
          keys = {}.compare_by_identity
          members.group_by(&:group).each { |group, found| assign(group, found, keys) }
          members.to_h { |member| [keys[member], member] }
        end

        private

        def assign(group, members, keys)
          slots = fill_gaps(same_text(group, members), @groups.fetch(group, []).size)
          seen = Hash.new(0)
          members.zip(slots) { |member, slot| keys[member] = slot ? [group, slot] : fresh(group, member, seen) }
        end

        # For each member, the place of the base member with its exact text, read in order.
        def same_text(group, members)
          texts = @groups.fetch(group, []).map(&:text)
          from = 0
          members.map do |member|
            found = (from...texts.size).find { |at| texts[at] == member.text }
            from = found + 1 if found
            found
          end
        end

        # Pairs each unplaced member with the next free base place before the next placed one.
        def fill_gaps(slots, size)
          floor = 0
          slots.each_index do |at|
            slots[at] ||= floor if floor < (slots[at..].compact.first || size)
            floor = slots[at] + 1 if slots[at]
          end
          slots
        end

        # A named addition is the same member on both branches; a nameless one only when its
        # text is the same, so two branches each adding an `attaches` keep both.
        def fresh(group, member, seen)
          mark = member.named ? :named : member.text
          [group, :new, mark, seen[mark] += 1]
        end
      end
    end
  end
end
