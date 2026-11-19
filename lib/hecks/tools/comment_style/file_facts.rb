# frozen_string_literal: true

require_relative "../../tools"

module Hecks
  module Tools
    module CommentStyle
      # What the linter learns from one Ruby file's text, apart from the file's path, so two files
      # with the same bytes share the facts and the path is bound only when they are reported.
      #
      # `found` holds every violation but the long blocks, in every category, as
      # `[line, category, message]`; `blocks` holds the blocks over `MAX_BLOCK` lines, which the
      # baseline judges at report time; `types` holds each class or module that is not only a
      # namespace, as `[fqn, line, documented]`, for the check that reads across files.
      FileFacts = Struct.new(:found, :blocks, :types) do
        # @param source [SourceFile] the parsed file
        # @return [FileFacts] what the file holds
        def self.of(source)
          found = source.violations.reject { |v| v.category == "long_block" }
          new(found.map { |v| [v.line, v.category, v.message] }, source.long_blocks.map(&:to_a), types_of(source))
        end

        # @param source [SourceFile] the parsed file
        # @return [Array<Array>] each type not only a namespace, as `[fqn, line, documented]`
        def self.types_of(source)
          source.types.reject(&:namespace_only).map { |type| [type.fqn, type.line, source.documented?(type)] }
        end

        # @param held [Hash] what {#to_h} wrote
        # @return [FileFacts] the same facts
        def self.from_h(held) = new(held["found"], held["blocks"], held["types"])

        # @param path [String] the file these facts were read from
        # @param baseline [Hash{String => Hash{String => Integer}}] the long blocks to tolerate
        # @return [Array<Violation>] the file's violations, long blocks included, in line order
        def violations(path, baseline)
          long = LongBlocks.refused(path, blocks.map { |row| Block.new(*row) }, baseline)
          (found.map { |row| Violation.new(path, *row) } + long).sort_by { |v| [v.line, v.category, v.message] }
        end

        # @return [Hash] the facts as JSON can hold them
        def to_h = { "found" => found, "blocks" => blocks, "types" => types }
      end
    end
  end
end
