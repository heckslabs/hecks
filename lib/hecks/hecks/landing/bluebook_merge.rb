# frozen_string_literal: true

require_relative "declarations"

module Hecks
  module Landing
    # The three-way merge of a bluebook by its declarations: what a landing tries when the same
    # bluebook was edited on both sides and git's line merge conflicts.
    #
    # Each declaration (see {Declarations}), and the head and tail around them, is taken from the
    # side that changed it; a change both sides made alike is taken once. A declaration changed
    # differently on both sides is refused by its name, and so is a merge whose text Ruby cannot
    # compile. A declaration only one side adds goes after the one that comes before it on that
    # side. It reads text and decides nothing beyond that rule; it touches no file.
    class BluebookMerge
      # Raised when the sides cannot be merged by declaration, naming why.
      class Refused < StandardError; end

      # The first line of a compiler's message.
      FIRST_LINE = /.*/

      # @param base [String] the common ancestor's text, empty when the file is new on both sides
      # @param ours [String] the text on the side being landed onto
      # @param theirs [String] the text on the side being landed
      def initialize(base, ours, theirs)
        @base = Declarations.new(base)
        @ours = Declarations.new(ours)
        @theirs = Declarations.new(theirs)
      end

      # @return [String] the merged text
      # @raise [Refused] naming the declaration changed on both sides, or the compile failure
      def merged
        text = [side("the head", &:head), *parts, side("the tail", &:tail)].join
        compiles(text)
        text
      end

      private

      def side(label)
        pick(label, yield(@base), yield(@ours), yield(@theirs))
      end

      def parts
        keys.filter_map { |key| pick(key, *[@base, @ours, @theirs].map { |doc| doc.by_key[key]&.text }) }
      end

      def pick(label, base, ours, theirs)
        return ours if ours == theirs || theirs == base
        return theirs if ours == base

        raise Refused, "#{label} changed on both sides"
      end

      # Our keys in order, with each key only theirs has placed after the one before it there.
      def keys
        theirs = @theirs.parts.map(&:key)
        theirs.each_with_index.with_object(@ours.parts.map(&:key)) do |(key, at), order|
          next if order.include?(key)

          before = theirs[0...at].reverse.find { |prior| order.include?(prior) }
          order.insert(before ? order.index(before) + 1 : 0, key)
        end
      end

      def compiles(text)
        RubyVM::InstructionSequence.compile(text)
      rescue SyntaxError => e
        raise Refused, "the merged bluebook does not compile: #{e.message[FIRST_LINE]}"
      end
    end
  end
end
