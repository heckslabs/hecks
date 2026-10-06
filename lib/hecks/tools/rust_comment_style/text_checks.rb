# frozen_string_literal: true

require_relative "../../tools"

module Hecks
  module Tools
    module RustCommentStyle
      # The prose categories: every check that reads one Rust comment's text.
      module TextChecks
        private

        def text_violations
          @comments.flat_map do |comment|
            next [] if comment.text.match?(TMPL_MARKER)

            caps_violations(comment) + constant_violations(comment) + unknown_violations(comment) +
              bold_violations(comment) + history_violations(comment) + length_violations(comment)
          end
        end

        def caps_violations(comment)
          caps_words(comment).map do |_, word, replacement|
            Violation.new(path, comment.line, "all_caps", "#{word} -> #{replacement}")
          end
        end

        def constant_violations(comment)
          words = mask(comment).scan(CommentStyle::CAPS_WORD).uniq
          words.select { |w| @constants.include?(w) && !CommentStyle::ACRONYMS.include?(w) }
               .map { |w| Violation.new(path, comment.line, "bare_constant", w) }
        end

        def unknown_violations(comment)
          words = mask(comment).scan(CommentStyle::CAPS_WORD).uniq - ["A"]
          words.reject { |w| keep_capitals?(w) }.select { |w| unknown?(w) }
               .map { |w| Violation.new(path, comment.line, "unknown_capitals", w) }
        end

        def bold_violations(comment)
          heading = comment.text[BOLD_HEADING, 2]
          return [] unless heading && heading.split.size > MAX_HEADING_WORDS

          [Violation.new(path, comment.line, "long_bold", "#{heading.split.size} words")]
        end

        def history_violations(comment)
          masked = comment.text.gsub(/`[^`]*`/) { |span| " " * span.length }
          pattern = CommentStyle::HISTORY.find { |candidate| masked.match?(candidate) }
          return [] unless pattern

          [Violation.new(path, comment.line, "design_history", %("#{masked[pattern]}"))]
        end

        def length_violations(comment)
          length = @lines[comment.line - 1].to_s.chomp.length
          return [] if length <= MAX_LINE

          [Violation.new(path, comment.line, "long_line", "#{length} characters")]
        end
      end
    end
  end
end
