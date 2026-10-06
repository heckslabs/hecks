# frozen_string_literal: true

require_relative "../../tools"

module Hecks
  module Tools
    module RustCommentStyle
      # The rewrites for the fixable categories: all-caps words, long bold headings, long lines.
      module Fixing
        private

        def fix_line(line, number, wanted)
          comment = @by_line[number]
          return line if comment.nil? || comment.text.match?(TMPL_MARKER)

          text = fixed_text(comment, wanted)
          code = line.byteslice(0, comment.col)
          return wrap(code, text) if wanted.include?("long_line") && comment.full_line

          "#{code}#{text}#{"\n" if line.end_with?("\n")}"
        end

        def fixed_text(comment, wanted)
          text = wanted.include?("all_caps") ? fix_caps(comment) : comment.text
          wanted.include?("long_bold") ? unbold(text) : text
        end

        def unbold(text)
          heading = text[BOLD_HEADING, 2]
          return text unless heading && heading.split.size > MAX_HEADING_WORDS

          text.sub(BOLD_HEADING) { "#{Regexp.last_match(1)}#{heading}" }
        end

        def fix_caps(comment)
          text = comment.text.dup
          found = caps_words(comment)
          found.reverse_each { |offset, word, replacement| text[offset, word.length] = replacement }
          first, last = heading_run(comment, found)
          return text unless first

          text.insert(last, "**").insert(first, "**")
        end

        def heading_run(comment, found)
          masked = mask(comment)
          return unless found.size >= 2 && paragraph_start?(comment, masked, found.first[0])

          run_bounds(found, masked)
        end

        # @return [Array(Integer, Integer), nil] where the first run of shouted words starts and
        #   ends, when it reads as a heading
        def run_bounds(found, masked)
          run = first_run(found, masked)
          finish = run_end(run, masked)
          return unless run.size >= 2 && masked[finish..].match?(HEADING_END)
          return if masked[run.first[0]...finish].split.size > MAX_HEADING_WORDS

          [run.first[0], finish]
        end

        # The leading shouted words with only a gap between them.
        def first_run(found, masked)
          found.slice_when { |(a, word, _), (b, _, _)| !masked[(a + word.length)...b].match?(GAP) }.first
        end

        # Where a run of shouted words ends, taking in a trailing possessive `'s`.
        def run_end(run, masked)
          finish = run.last[0] + run.last[1].length
          masked[finish, 2] == "'s" ? finish + 2 : finish
        end

        def paragraph_start?(comment, masked, offset)
          return false if masked[0, offset].sub(MARKER, "").match?(/[[:alnum:]#{FILLER}]/o)

          above = comment.full_line ? @by_line[comment.line - 1] : nil
          !above&.full_line || above.text.match?(%r{\A/{2,3}!?\s*\z})
        end

        # Splits one over-long prose comment line in two. Lines with no safe
        # break point (a long URL, an unbroken code span) are left for a person.
        def wrap(indent, text)
          whole = "#{indent}#{text}\n"
          return whole if whole.chomp.length <= MAX_LINE

          lead = text[MARKER].to_s
          cut = wrap_cut(indent, text, lead)
          return whole unless cut

          "#{indent}#{text[0, cut].rstrip}\n#{wrap(indent, "#{lead}#{text[cut..].strip}")}"
        end

        # @return [Integer, nil] the offset to break at, nil when there is no safe one
        def wrap_cut(indent, text, lead)
          cut = text[0, MAX_LINE - indent.length + 1].rindex(" ")
          cut unless cut.nil? || cut <= lead.length || text[0, cut].count("`").odd?
        end
      end
    end
  end
end
