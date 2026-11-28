# frozen_string_literal: true

require_relative "area_overlap"
require "hecks/hecks/adapters/landing/section_area"

module Hecks
  module Adapters
    # The bluebooks two work items share by sections: a file both name, each by declarations the
    # other does not hold (`x.bluebook#Coder` and `x.bluebook#Brief`). Such a pair is not an
    # overlap ({AreaOverlap} keeps it apart), so both may start; this names it, so each coder is
    # told the other works in the same file. It measures and decides nothing.
    module SharedSections
      # One shared file: its path and the sections the other work item holds there.
      Share = Struct.new(:path, :theirs)

      module_function

      # @param mine [Array<String>] one work item's area words
      # @param theirs [Array<String>] another's area words
      # @param root [String, nil] the repository's top level, to make absolute paths relative
      # @return [Array<Share>] each file both name by different sections, once
      def between(mine, theirs, root: nil)
        pairs = mine.product(theirs).select { |one, other| shared?(one, other, root) }
        pairs.map { |one, other| Share.new(Landing::SectionArea.path(one), Landing::SectionArea.sections(other)) }
             .uniq(&:path)
      end

      # The clause a coordination line ends with when the other work item shares a file with
      # this one, empty when it shares none.
      #
      # @param mine [Array<String>] the area words of the work item being started
      # @param theirs [Array<String>] the area words of a work item already holding ground
      # @param root [String, nil] the repository's top level
      # @return [String]
      def notice(mine, theirs, root: nil)
        between(mine, theirs, root: root).map do |share|
          "; shares #{share.path} with you: it holds #{share.theirs.join(", ")}, edit only your own sections of it"
        end.join
      end

      # Both words name sections, none in common, of one file.
      def shared?(one, other, root)
        Landing::SectionArea.apart?(one, other) &&
          AreaOverlap.overlap?(Landing::SectionArea.path(one), Landing::SectionArea.path(other), root: root)
      end
    end
  end
end
