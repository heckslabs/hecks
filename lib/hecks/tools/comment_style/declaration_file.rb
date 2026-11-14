# frozen_string_literal: true

require_relative "../../tools"

module Hecks
  module Tools
    module CommentStyle
      # One declaration file (a bluebook, hecksagon, world, adapter or behaviors file), read for
      # its comment blocks alone.
      #
      # A declaration says what the domain is, so a long comment above one is the declaration left
      # unclear and explained beside itself. A run of full-line comments longer than
      # `MAX_DECLARATION_BLOCK` is a `long_block` here, held against the same baseline a Ruby
      # file's blocks are: what the block says belongs in a name, a `description` or a `goal`.
      class DeclarationFile
        # A full-line comment.
        COMMENT_LINE = /\A\s*#/

        # What the refusal tells the writer to do instead.
        ADVICE = "say it in the declaration (a name, a description, a goal), not above it"

        attr_reader :path

        # @param path [String] the file
        # @param source [String, nil] its text; read from `path` when nil
        def initialize(path, source = nil)
          @path = path
          @lines = (source || File.read(path, encoding: Encoding::UTF_8)).lines
        end

        # Every run of full-line comments longer than `MAX_DECLARATION_BLOCK`.
        #
        # @return [Array<Block>] each block's first line, its length and its baseline key
        def long_blocks
          seen = Hash.new(0)
          runs.select { |run| run.size > MAX_DECLARATION_BLOCK }
              .map { |run| Block.new(run.first.last, run.size, key_of(run, seen)) }
        end

        # A block fails when it has no baseline entry, or has grown past the length held there.
        #
        # @param baseline [Hash{String => Hash{String => Integer}}] the blocks already held
        # @return [Array<Violation>]
        def violations(baseline: {})
          held = baseline.fetch(path.delete_prefix("./"), {})
          long_blocks.filter_map do |block|
            allowed = held[block.key]
            next if allowed && block.lines <= allowed

            Violation.new(path, block.line, "long_block", refusal(block, allowed))
          end
        end

        private

        # Each run of consecutive comment lines, as pairs of the line's text and its number.
        def runs
          numbered = @lines.each_with_index.map { |text, index| [text, index + 1] }
          numbered.chunk_while { |above, below| comment?(above) && comment?(below) }.select { |run| comment?(run.first) }
        end

        def comment?(pair) = pair.first.match?(COMMENT_LINE)

        # Keyed as a Ruby file's block is: by the text of its first line, with `#2` for a second
        # block opened by the same text.
        def key_of(run, seen)
          text = run.first.first.strip.sub(COMMENT_MARKER, "").strip[0, MAX_ANCHOR]
          text = "(empty)" if text.empty?
          seen[text] += 1
          seen[text] == 1 ? text : "#{text} ##{seen[text]}"
        end

        def refusal(block, allowed)
          detail = allowed ? "baselined at #{allowed}" : "over #{MAX_DECLARATION_BLOCK} in a declaration file"
          "#{block.lines} lines, #{detail}; #{ADVICE}: #{block.key}"
        end
      end
    end
  end
end
