require "prism"
require_relative "merge/outline"
require_relative "merge/three_way"

module Hecks
  module Bluebook
    # Merges two branches' versions of one bluebook, hecksagon or world file by what they
    # declare, not by their lines: each branch adding a command to one aggregate merges, and both
    # changing one attribute or invariant is a conflict named by aggregate and member.
    #
    # It sits beside the constructs because its members are theirs (aggregate, command,
    # attribute, policy), read from the text each was declared in. It only parses: it loads no
    # domain, reads no file and runs no git, so a caller hands it three texts and decides what to
    # do with the answer.
    module Merge
      # Raised when a text given to the merge is not valid Ruby; the message names which one.
      class Unreadable < StandardError; end

      # Raised when the text of a merge that ended in conflicts is asked for.
      class Conflicted < StandardError; end

      # What a merge answers: the merged text, or the conflicts that stopped it.
      class Result
        # @return [Array<Conflict>] the members the branches disagree on; empty for a clean merge
        attr_reader :conflicts

        # @param text [String] the merged source
        # @param conflicts [Array<Conflict>] what could not be settled
        def initialize(text, conflicts)
          @text = text
          @conflicts = conflicts.freeze
        end

        # @return [Boolean] whether every member was settled
        def clean? = conflicts.empty?

        # @return [String] the merged source
        # @raise [Conflicted] if the merge is not clean, so a half-merged file is never written
        def text
          raise Conflicted, conflicts.join("; ") unless clean?

          @text
        end
      end

      module_function

      # @param base [String] the file as both branches began with it
      # @param ours [String] the file on the branch being merged into
      # @param theirs [String] the file on the branch being merged
      # @return [Result] the merged text, or the conflicts
      # @raise [Unreadable] if one of the three texts does not parse
      def call(base:, ours:, theirs:)
        roots = { "base" => base, "ours" => ours, "theirs" => theirs }.map { |side, text| outline(side, text) }
        way = ThreeWay.new
        merged = way.settle(Trio.new(*roots), []).text
        Result.new(merged, way.conflicts + unparsable(merged, way.conflicts))
      end

      # @api private
      def outline(side, text)
        Outline.call(text)
      rescue Unreadable => e
        raise Unreadable, "#{side} does not parse: #{e.message}"
      end

      # A clean merge whose text is not valid Ruby is a conflict of the whole file.
      # @api private
      def unparsable(merged, conflicts)
        return [] if conflicts.any? || ::Prism.parse(merged).success?

        [Conflict.new(kind: :unparsable, owners: [], word: "file", name: nil, named: false)]
      end
    end
  end
end
