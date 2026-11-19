# frozen_string_literal: true

module Hecks
  module Landing
    # An area word that may name declared sections of one bluebook:
    # `lib/x/x.bluebook#Coder,Brief` claims only the declarations named `Coder` and `Brief` in
    # that file, so two Work items may hold one bluebook while their sections differ.
    #
    # The path before `#` is an ordinary area; the names after it are declaration names, comma
    # separated. A word with no `#` names no sections and claims the whole path.
    module SectionArea
      # What divides the path from the sections.
      MARK = "#"

      module_function

      # @param word [String] an area word
      # @return [String] the path the word claims, without its sections
      def path(word) = halves(word).first.to_s

      # @param word [String] an area word
      # @return [Array<String>] the declaration names it claims, empty when it claims the whole path
      def sections(word)
        named = halves(word)[1]
        named ? named.split(",").map(&:strip).reject(&:empty?) : []
      end

      # Whether two words are kept apart by their sections: both name sections and none is shared.
      # A word with no sections is never apart from another; the paths then decide.
      #
      # @param one [String] an area word
      # @param other [String] an area word
      # @return [Boolean]
      def apart?(one, other)
        mine = sections(one)
        theirs = sections(other)
        !mine.empty? && !theirs.empty? && !mine.intersect?(theirs)
      end

      # @param word [String] an area word
      # @return [Boolean] whether it names sections
      def sectioned?(word) = !sections(word).empty?

      # @param word [String] an area word
      # @return [Array<String>] the path and, when there is one, the text after the mark
      def halves(word) = word.to_s.split(MARK, 2)
    end
  end
end
