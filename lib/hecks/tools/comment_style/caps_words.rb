# frozen_string_literal: true

require_relative "../../tools"

module Hecks
  module Tools
    module CommentStyle
      # Finds the all-caps words in a comment and decides how each should be written instead.
      module CapsWords
        private

        # @return [Array<Array>] each shouted word as `[offset, word, replacement]`, in text order
        def caps_words(comment)
          masked = mask(comment)
          matches = []
          masked.scan(CAPS_WORD) { matches << Regexp.last_match }
          sql = sql_keywords(comment, matches.map { |match| match[0] })
          found = matches.filter_map { |match| shouted_word(comment, masked, match, sql) }
          (drop_stray_articles(found) + possessives(masked)).sort_by(&:first)
        end

        def shouted_word(comment, masked, match, sql)
          word = match[0]
          return if word != "A" && (keep_capitals?(word) || sql.include?(word) || unknown?(word))

          [match.begin(0), word, recase(word, sentence_start?(comment, masked, match.begin(0)))]
        end

        # `Finding`'s: the capital follows a code span, so `CAPS_WORD` never sees it.
        def possessives(masked)
          found = []
          masked.scan(/(?<=#{FILLER})'S\b/) { found << [Regexp.last_match.begin(0) + 1, "S", "s"] }
          found
        end

        # An "A" is only emphasis when a word beside it is being fixed too.
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

        # A shouted product or class name (`POSTGRESERA`) gets its real spelling
        # back. An English word that is also a class name (`VALUE`) stays prose.
        def proper_name(bare)
          PROPER_NOUNS[bare] || (CommentStyle.class_names[bare] unless Dictionary.english?(bare))
        end

        # Neither English nor a known name, so lowercasing it would be a guess.
        def unknown?(word)
          bare = word.split("'", 2).first
          !Dictionary.english?(word) && !proper_name(bare)
        end

        def keep_capitals?(word)
          bare = word.sub(/'[A-Z]{1,2}\z/, "")
          return false if PROPER_NOUNS.key?(bare)

          ACRONYMS.include?(bare) || @constants.include?(bare) || bare.match?(/\A[IVX]+\z/)
        end

        def sentence_start?(comment, masked, offset)
          before = masked[0, offset].sub(/\A#+\s*/, "")
          return before.match?(/[.!?]["')\]]*\s+\z/) if before.match?(/[[:alnum:]#{FILLER}]/)
          return true if before.match?(/\A\s*(?:[-*•]|─+|\d+[.)])\s+\z/)
          return false if masked[0, offset].match?(/\A#\s{3,}/)

          after_sentence_end?(comment)
        end

        # Whether the line above, in the same paragraph, ends a sentence (or there is none).
        def after_sentence_end?(comment)
          previous = comment.full_line ? @by_line[comment.line - 1] : nil
          return true unless previous&.full_line

          body = previous.text.sub(/\A#+\s*/, "").strip
          body.empty? || body.match?(/[.!?]["')\]]*\z/)
        end
      end
    end
  end
end
