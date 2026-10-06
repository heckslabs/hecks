# frozen_string_literal: true

require_relative "../../tools"

module Hecks
  module Tools
    module HoistLocalGivens
      # Edits a bluebook's source text: finds an owner's window and swaps a rule's repeated
      # occurrences for bare references behind one owner-level `given`.
      module Rewriting
        # Opens a nested entity block, which the scan carves out of its owner.
        ENTITY_OPEN = /^([ \t]*)entity\s+"[^"]+"\s+do\n/

        # The owner's own window: its opening line to the next `end` at the same indentation.
        # `collect_rules` yields a dotted owner ("Account.LedgerEntry") but the source spells the
        # bare name, so the last segment is matched; a name that is not unique in the file is
        # skipped.
        #
        # @param text [String] a bluebook's source
        # @param owner [String] the owner's dotted name
        # @return [Array(MatchData, Integer), nil] the opening line's match and the closing offset
        def owner_window(text, owner)
          bare_name = owner.split(".").last
          open_re = /^([ \t]*)(?:aggregate|entity)\s+"#{Regexp.escape(bare_name)}"\s+do\n/
          return nil if text.scan(open_re).size != 1

          open_match = text.match(open_re)
          indent = open_match[1]
          close_at = text.index(/^#{indent}end\n/, open_match.end(0))
          return nil unless close_at

          [open_match, close_at]
        end

        # Nested entity blocks are carved out of the scan: an entity may declare a `given` with the
        # same description but a different predicate.
        #
        # @param window [String] the owner's source
        # @return [Array<Array(String, Boolean)>] each stretch of source, and whether it is nested
        def strip_nested_entities(window)
          segments = []
          pos = 0
          while (m = window.match(ENTITY_OPEN, pos)) && (end_match = window.match(/^#{m[1]}end\n/, m.end(0)))
            segments << [window[pos...m.begin(0)], false] << [window[m.begin(0)...end_match.end(0)], true]
            pos = end_match.end(0)
          end
          segments << [window[pos..], false]
        end

        # A match needs the predicate to equal the candidate's canonical, not just the description:
        # the same words can carry a different rule (`disputed_by.status` vs
        # `account.customer.status`).
        #
        # @param predicate_src [String] a `given`'s block source
        # @param candidate [Candidate] the rule being hoisted
        # @return [Boolean] whether it is the same rule
        def matching_occurrence?(predicate_src, candidate)
          predicate_src.strip == candidate.canonical
        end

        # @param description [String] a `given`'s description
        # @return [Regexp] the line that declares it with a block
        def desc_pattern_for(description)
          /^([ \t]*)given\(#{Regexp.escape(description.inspect)}\)\s*\{([^\n}]*)\}\n/
        end

        # @param text [String] a bluebook's source
        # @param candidate [Candidate] the rule to hoist
        # @return [Array(String, Boolean)] the new source and whether the rule was hoisted
        def apply_candidate(text, candidate)
          window = hoistable_window(text, candidate)
          return [text, false] unless window

          open_match, close_at, segments, pattern = window
          bare_window = segments.map { |seg, nested| nested ? seg : bare_references(seg, pattern, candidate) }.join
          [text[0...open_match.end(0)] + owner_given(open_match, candidate) + bare_window + text[close_at..], true]
        end

        private

        # @return [Array, nil] the owner's opening match, the closing offset, the window's segments
        #   and the pattern of the rule's occurrences, when two or more occurrences can be hoisted
        def hoistable_window(text, candidate)
          bounds = owner_window(text, candidate.owner)
          return nil unless bounds

          open_match, close_at = bounds
          segments = strip_nested_entities(text[open_match.end(0)...close_at])
          pattern = desc_pattern_for(candidate.description)
          [open_match, close_at, segments, pattern] if outside_matches(segments, pattern, candidate).size >= 2
        end

        # The owner-level `given`, indented one level inside the owner, not as deep as the
        # occurrence in a command block.
        def owner_given(open_match, candidate)
          "#{open_match[1]}  given(#{candidate.description.inspect}) { #{candidate.canonical} }\n"
        end

        # The candidate's occurrences outside nested entities.
        def outside_matches(segments, pattern, candidate)
          segments.flat_map { |seg, nested| nested ? [] : seg.scan(pattern) }
                  .select { |_, predicate_src| matching_occurrence?(predicate_src, candidate) }
        end

        # `seg` with each of the candidate's occurrences swapped for a bare reference.
        def bare_references(seg, pattern, candidate)
          seg.gsub(pattern) do
            indent, predicate_src = Regexp.last_match.captures
            if matching_occurrence?(predicate_src, candidate)
              "#{indent}given(#{candidate.description.inspect})\n"
            else
              Regexp.last_match(0)
            end
          end
        end
      end
    end
  end
end
