# frozen_string_literal: true

require_relative "../../tools"

module Hecks
  module Tools
    module CommentStyle
      # The prose categories: every check that reads one comment's text.
      module TextChecks
        private

        def text_violations
          @comments.flat_map do |comment|
            next [] if comment.text.match?(DIRECTIVE)

            caps_violations(comment) + constant_violations(comment) + unknown_violations(comment) +
              bold_violations(comment) + history_violations(comment) + length_violations(comment)
          end
        end

        def unknown_violations(comment)
          words = mask(comment).scan(CAPS_WORD).uniq - ["A"]
          words.reject { |word| keep_capitals?(word) }.select { |word| unknown?(word) }.map do |word|
            Violation.new(path, comment.line, "unknown_capitals", word)
          end
        end

        def bold_violations(comment)
          heading = comment.text[BOLD_HEADING, 2]
          return [] unless heading && heading.split.size > MAX_HEADING_WORDS

          [Violation.new(path, comment.line, "long_bold", "#{heading.split.size} words")]
        end

        def caps_violations(comment)
          caps_words(comment).map do |_, word, replacement|
            Violation.new(path, comment.line, "all_caps", "#{word} -> #{replacement}")
          end
        end

        # A capitalised word that is also a constant defined in this file could be
        # either prose or a reference, so it is reported rather than rewritten.
        def constant_violations(comment)
          words = mask(comment).scan(CAPS_WORD).uniq
          words.select { |word| @constants.include?(word) && !ACRONYMS.include?(word) }.map do |word|
            Violation.new(path, comment.line, "bare_constant", word)
          end
        end

        def history_violations(comment)
          masked = comment.text.gsub(/`[^`]*`/) { |span| " " * span.length }
          pattern = HISTORY.find { |candidate| masked.match?(candidate) }
          return [] unless pattern

          [Violation.new(path, comment.line, "design_history", %("#{masked[pattern]}"))]
        end

        def length_violations(comment)
          length = @lines[comment.line - 1].chomp.length
          return [] if length <= MAX_LINE

          [Violation.new(path, comment.line, "long_line", "#{length} characters")]
        end
      end
    end
  end
end
