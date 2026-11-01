# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # The words a session is started with, laid out from a composed brief. Every sentence in it is the
      # Coder bluebook's; this only orders the sections, fills in the row's key and lists the areas the
      # caller knows.
      class BriefText
        # The sections of a brief after the outcome, in the order they are read.
        SECTIONS = %w[rules verification workflow landing restraints report].freeze

        # @param brief [Hash] the composed brief: its attribute values by name
        def initialize(brief)
          @brief = brief
        end

        # @return [String] the first line of the text: the outcome
        def first_line = "Outcome: #{plain("outcome")}"

        # @param key [String] the Work row's key, which names the worktree and branch
        # @param area [Array<String>] the areas the session may edit
        # @param held [Array<String>] a line for each area another started row holds
        # @param frozen [Array<String>] the areas and aggregates whose shape may not move
        # @return [String] the whole text
        def render(key, area: [], held: [], frozen: [])
          parts = [first_line, labelled("Detail", plain("detail")), labelled("Area", area.join(", "))]
          parts += SECTIONS.map { |name| plain(name) }
          parts += [listed("coordination", held), listed("freeze", frozen)]
          joined(parts).gsub("{work}", key)
        end

        private

        def labelled(label, text) = text.empty? ? nil : "#{label}: #{text}"

        def listed(name, lines) = lines.empty? ? nil : ([plain(name)] + lines.map { |line| "- #{line}" }).join("\n")

        def joined(parts) = parts.compact.reject(&:empty?).join("\n\n")

        # A value is a bare string or a one-field hash, and a name is a string or a symbol.
        def plain(name)
          found = @brief.transform_keys(&:to_s)[name]
          (found.is_a?(Hash) ? found.transform_keys(&:to_s)["value"] : found).to_s
        end
      end
    end
  end
end
