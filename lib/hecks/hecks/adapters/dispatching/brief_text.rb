# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # The words a session is started with, laid out from a composed brief. Every sentence in it is
      # the
      # Coder bluebook's; this only orders the sections, fills in the work item's key and lists the
      # areas
      # the
      # caller knows.
      class BriefText
        # The sections of a brief after the outcome, in the order they are read.
        SECTIONS = %w[rules review verification workflow landing restraints report].freeze

        # @param brief [Hash] the composed brief: its attribute values by name
        def initialize(brief)
          @brief = brief
        end

        # @return [String] the first line of the text: the outcome
        def first_line = "Outcome: #{plain("outcome")}"

        # @param key [String] the Work item's key, which names the worktree and branch
        # @param area [Array<String>] the areas the session may edit
        # @param limit [Integer, nil] spec files per call, from the world's `test_scope`;
        #   fills `{limit}`
        # @param main [String, nil] the primary checkout the fill runs from; fills `{main}`
        # @param lines [Hash] `held:` a line for each area another started work item holds,
        #   `frozen:` the areas whose shape may not move, `traps:` a line for each known trap;
        #   each is an Array of strings and defaults to none
        # @return [String] the whole text
        # @raise [ArgumentError] if the text names `{main}` and no `main:` was given
        def render(key, area: [], limit: nil, main: nil, **lines)
          parts = [first_line, lines[:rethinks].to_s, *detail_parts(area)]
          parts += SECTIONS.map { |name| plain(name) } + lists(lines)
          text = joined(parts).gsub("{work}", key).gsub("{limit}", limit&.to_s || "the world's spec_files_limit")
          fill_main(text, main)
        end

        private

        def detail_parts(area) = [labelled("Detail", plain("detail")), labelled("Area", area.join(", "))]

        def fill_main(text, main)
          return text unless text.include?("{main}")
          raise ArgumentError, "the brief names {main} and no main checkout was given" if main.to_s.empty?

          text.gsub("{main}", main.to_s.chomp("/"))
        end

        # The lists a caller fills, each under its heading, in the order the brief reads them.
        def lists(lines)
          [listed("known traps", lines.fetch(:traps, [])), listed("coordination", lines.fetch(:held, [])),
           listed("freeze", lines.fetch(:frozen, []))]
        end

        def labelled(label, text) = text.empty? ? nil : "#{label}: #{text}"

        def listed(name, lines) = lines.empty? ? nil : ([heading(name)] + lines.map { |line| "- #{line}" }).join("\n")

        # The standing sections are read from the bluebook; a list a caller fills is headed here.
        def heading(name) = name == "known traps" ? "Known traps:" : plain(name)

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
