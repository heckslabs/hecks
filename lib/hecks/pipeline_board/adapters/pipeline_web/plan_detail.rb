# frozen_string_literal: true

require "cgi"

module Hecks
  module Adapters
    module PipelineBoard
      # A Work item's detail on the planning page: one line saying what it is, and the whole text
      # behind a click. The line is the detail's first sentence, cut at {PlanDetail::LIMIT}
      # characters before it is escaped, so an entity is never split.
      module PlanDetail
        # The longest the one-line summary is, ellipsis included.
        LIMIT = 140
        # Where a sentence ends: after a full stop, question or exclamation mark, or at a new line.
        SENTENCE_END = /(?<=[.!?])\s|\n/

        module_function

        # @param row [Hash] a row of {PlanReading}; its `detail` is the Work item's text
        # @return [String] a closed details element, or nothing when the item has no detail
        def draw(row)
          text = row[:detail].to_s.strip
          return "" if text.empty?

          "<details class=\"detail\"><summary>#{esc(summary(text))}</summary><pre>#{esc(text)}</pre></details>"
        end

        # @param text [String] a detail
        # @return [String] its first sentence, at most {PlanDetail::LIMIT} characters
        def summary(text)
          line = first_sentence(text)
          line.length > LIMIT ? "#{line[0, LIMIT - 1].rstrip}…" : line
        end

        def first_sentence(text)
          sentences = text.to_s.strip.split(SENTENCE_END, 2)
          sentences.first.to_s
        end

        def esc(text) = CGI.escapeHTML(text.to_s)
      end
    end
  end
end
