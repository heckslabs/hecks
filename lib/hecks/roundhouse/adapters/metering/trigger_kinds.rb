# frozen_string_literal: true

module Hecks
  module Adapters
    class Metering
      # The declared trigger kinds, data only: the first row whose pattern matches the opening text
      # of a turn's prompt names what set the turn going. A prompt no row matches is a `user prompt`
      # when a person typed it and `other` when not. The text is read here and never leaves: only
      # the label reaches the report.
      module TriggerKinds
        ROWS = [
          { pattern: /\A\s*<task-notification>/, label: "task notification" },
          { pattern: /\A\s*Stop hook feedback/, label: "hook feedback" },
          { pattern: /\A\s*\[pipeline answer\]/i, label: "pipeline answer" },
          { pattern: /\A\s*(Read the notifications|<scheduled)/, label: "watch pass" },
          { pattern: /\A\s*<(system-reminder|command-name)>/, label: "system message" }
        ].freeze

        TYPED = "user prompt"
        OTHER = "other"

        module_function

        # @param text [String] the prompt's text
        # @param typed [Boolean] whether a person typed it
        # @return [String] the label of the first row that matches, else `user prompt` or `other`
        def label(text, typed: false)
          row = ROWS.find { |entry| entry[:pattern].match?(text.to_s) }
          return row[:label] if row

          typed ? TYPED : OTHER
        end

        # @return [Array<String>] every label, in row order, then the two fallbacks
        def labels = ROWS.map { |entry| entry[:label] } + [TYPED, OTHER]
      end
    end
  end
end
