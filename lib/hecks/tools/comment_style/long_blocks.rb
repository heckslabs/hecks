# frozen_string_literal: true

require_relative "../../tools"

module Hecks
  module Tools
    module CommentStyle
      # The `long_block` category: runs of full-line comments longer than `MAX_BLOCK`, held
      # against the baseline.
      module LongBlocks
        # Finds every run of consecutive full-line comments longer than `MAX_BLOCK`.
        #
        # @return [Array<Block>]
        def long_blocks
          return [] if generated?

          seen = Hash.new(0)
          long_runs = comment_runs.select { |run| run.size > MAX_BLOCK }
          long_runs.map { |run| Block.new(run.first.line, run.size, block_key(run, seen)) }
        end

        private

        def comment_runs
          @comments.select(&:full_line).slice_when { |above, below| below.line != above.line + 1 }
        end

        # The text of a block's first line, without its `#`, is its key. A second block opened by
        # the same text in this file gets a `#2` suffix, and so on.
        def block_key(run, seen)
          text = run.first.text.sub(/\A#+\s*/, "").strip[0, MAX_ANCHOR]
          text = "(empty)" if text.empty?
          seen[text] += 1
          seen[text] == 1 ? text : "#{text} ##{seen[text]}"
        end

        # A block fails when it has no baseline entry, or has grown past the length recorded there.
        def long_block_violations(baseline)
          held = baseline.fetch(path.delete_prefix("./"), {})
          long_blocks.filter_map do |block|
            allowed = held[block.key]
            next if allowed && block.lines <= allowed

            detail = allowed ? "baselined at #{allowed}" : "over #{MAX_BLOCK}"
            Violation.new(path, block.line, "long_block", "#{block.lines} lines, #{detail}: #{block.key}")
          end
        end
      end
    end
  end
end
