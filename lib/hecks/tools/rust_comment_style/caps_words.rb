# frozen_string_literal: true

require_relative "../../tools"

module Hecks
  module Tools
    module RustCommentStyle
      # Finds the all-caps words in a Rust comment and decides how each should be written instead.
      module CapsWords
        private

        def caps_words(comment)
          masked = mask(comment)
          matches = []
          masked.scan(CommentStyle::CAPS_WORD) { matches << Regexp.last_match }
          sql = sql_keywords(comment, matches.map { |m| m[0] })
          found = matches.filter_map { |match| shouted_word(comment, masked, match, sql) }
          (drop_stray_articles(found) + possessives(masked)).sort_by(&:first)
        end

        def shouted_word(comment, masked, match, sql)
          word = match[0]
          return if word != "A" && (keep_capitals?(word) || sql.include?(word) || unknown?(word))

          [match.begin(0), word, recase(word, sentence_start?(comment, masked, match.begin(0)))]
        end

        def possessives(masked)
          found = []
          masked.scan(/(?<=#{FILLER})'S\b/) { found << [Regexp.last_match.begin(0) + 1, "S", "s"] }
          found
        end

        def drop_stray_articles(found)
          found.each_with_index.reject do |(offset, word, _), index|
            word == "A" && !beside_fixed_word?(found, index, offset)
          end.map(&:first)
        end

        def beside_fixed_word?(found, index, offset)
          before = index.positive? ? found[index - 1] : nil
          after = found[index + 1]
          follows_fixed?(before, offset) || precedes_fixed?(after, offset)
        end

        def follows_fixed?(before, offset)
          before && before[0] + before[1].length + 1 == offset && before[1] != "A"
        end

        def precedes_fixed?(after, offset)
          after && after[0] == offset + 2 && after[1] != "A"
        end

        def recase(word, sentence_start)
          bare, suffix = word.split("'", 2)
          proper = proper_name(bare)
          return [proper, suffix&.downcase].compact.join("'") if proper

          sentence_start ? word.capitalize : word.downcase
        end

        def proper_name(bare)
          CommentStyle::PROPER_NOUNS[bare] || RUST_PROPER_NOUNS[bare]
        end

        def unknown?(word)
          bare = word.split("'", 2).first
          !CommentStyle::Dictionary.english?(word) && !proper_name(bare)
        end

        def keep_capitals?(word)
          bare = word.sub(/'[A-Z]{1,2}\z/, "")
          return false if CommentStyle::PROPER_NOUNS.key?(bare) || RUST_PROPER_NOUNS.key?(bare)

          CommentStyle::ACRONYMS.include?(bare) || RUST_ACRONYMS.include?(bare) ||
            @constants.include?(bare) || bare.match?(/\A[IVX]+\z/)
        end

        def sentence_start?(comment, masked, offset)
          before = masked[0, offset].sub(MARKER, "")
          return before.match?(/[.!?]["')\]]*\s+\z/) if before.match?(/[[:alnum:]#{FILLER}]/)
          return true if before.match?(/\A\s*(?:[-*•]|─+|\d+[.)])\s+\z/)

          after_sentence_end?(comment)
        end

        # Whether the line above, in the same paragraph, ends a sentence (or there is none).
        def after_sentence_end?(comment)
          previous = comment.full_line ? @by_line[comment.line - 1] : nil
          return true unless previous&.full_line

          body = previous.text.sub(MARKER, "").strip
          body.empty? || body.match?(/[.!?]["')\]]*\z/)
        end
      end
    end
  end
end
