require_relative "../../text"

module Hecks
  module CLI
    module InterviewShape
      # The lifecycle an interview's accepted transitions describe, and the state words it is
      # written in. `InterviewShape` extends it, so each method answers on `InterviewShape`.
      module Lifecycle
        # A run of anything a state word may not hold.
        NON_STATE_CHARACTERS = /[^a-z0-9]+/
        # An underscore at either end of a word.
        EDGE_UNDERSCORE = /\A_|_\z/

        # The lifecycle the accepted transitions describe. The state a creating action's step
        # leads to is where a thing starts; a step for an action the thing does not have is kept
        # as a comment.
        #
        # @param steps [Array<Hash>] the thing's accepted transitions
        # @param creating [Array<Hash>] the accepted actions that create it
        # @param rest [Array<Hash>] its other accepted actions
        # @return [Array<String>] the lines, or none when no step and start state can be placed
        def lifecycle(steps, creating, rest)
          starts, moves = steps.partition { |step| names_action?(creating, step) }
          placed, loose = moves.partition { |step| names_action?(rest, step) }
          placed = merged(placed)
          start = beginning(starts, placed)
          return [] if start.empty? || placed.empty?

          lifecycle_block(start, placed, loose)
        end

        # @api private
        def lifecycle_block(start, placed, loose)
          ["", "    lifecycle :status, default: #{start.inspect} do", *placed.map { |step| transition_line(step) },
           "    end", *loose.map { |step| loose_line(step) }]
        end

        # @api private
        def names_action?(actions, step)
          actions.map { |action| InterviewDraft.word(action[:name]) }.include?(InterviewDraft.word(step[:action]))
        end

        # One step for each action and state it leads to: the states it starts from are joined,
        # and a step with no state to start from means it may be taken from any.
        # @api private
        def merged(steps)
          steps.group_by { |step| [InterviewDraft.word(step[:action]), state_word(step[:to])] }.values.map do |group|
            froms = group.map { |step| step[:from].to_s.strip }
            group.first.merge(from: froms.any?(&:empty?) ? "" : froms.join(","))
          end
        end

        # The state a thing starts in: where its creating action's step leads, else the first state
        # a change is said to start from.
        # @api private
        def beginning(starts, placed)
          from = placed.map { |step| step[:from].to_s.split(",").first }.find { |text| !text.to_s.strip.empty? }
          state_word(starts.first&.fetch(:to) || from)
        end

        # @api private
        def transition_line(step)
          "      transition #{InterviewDraft.word(step[:action]).inspect} => #{state_word(step[:to]).inspect}" \
            "#{from_clause(step)}"
        end

        # @api private
        def loose_line(step)
          "    # UNPLACED transition: #{InterviewDraft.word(step[:action])} to #{state_word(step[:to])}; " \
            "no accepted action has that name."
        end

        # The states a step may start from: none, one, or several.
        # @api private
        def from_clause(step)
          froms = step[:from].to_s.split(Text::COMMA).map { |text| state_word(text) }
          states = froms.reject(&:empty?)
          return "" if states.empty?

          states.one? ? ", from: #{states.first.inspect}" : ", from: %w[#{states.join(" ")}]"
        end

        # A state as a lowercase word: `Not Yet Triaged` is `not_yet_triaged`.
        # @api private
        def state_word(text)
          lowered = text.to_s.strip.downcase
          lowered.gsub(NON_STATE_CHARACTERS, "_").gsub(EDGE_UNDERSCORE, "")
        end
      end
    end
  end
end
