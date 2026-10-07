# frozen_string_literal: true

module Hecks
  module Projections
    module Site
      module CmsEditor
        # Which commands the editor asks a person to confirm before it runs them, and what colour
        # each lifecycle state's badge has.
        #
        # A command is destructive when its first word is one of `WORDS` (`WithdrawOffer`,
        # `DiscardDraft`), or when it is a lifecycle move into a state named for one of `STATES`.
        # The test reads the bluebook's own words and structure, never a list of aggregates, so a
        # domain with a different vocabulary confirms nothing it did not name that way. A move that
        # can be undone, such as an archive with a restore, is not destructive by that alone.
        #
        # A state's tone is structural: the starting state is `neutral`, a state named for a
        # destructive word is `danger`, and the others alternate `ok` and `info` in the order the
        # moves reach them. The badge always carries the state's name; tone is never the only cue.
        module Destructive
          # The first words of a command that undoes or ends something.
          WORDS = %w[withdraw retire discard delete cancel remove].freeze

          # The states those commands move into.
          STATES = %w[withdrawn retired discarded deleted cancelled canceled removed].freeze

          module_function

          # @param name [String] the command's name, such as `"DiscardDraft"`
          # @param lifecycle [Hash{String => Object}, nil] the lifecycle as `Schema` reads it
          # @return [Boolean] whether the editor confirms the command first
          def command?(name, lifecycle)
            return true if WORDS.include?(words(name).first)

            move = lifecycle && lifecycle["transitions"].find { |transition| transition["verb"] == name }
            !move.nil? && STATES.include?(move["to"].downcase)
          end

          # @param lifecycle [Hash{String => Object}, nil] the lifecycle as `Schema` reads it
          # @return [Hash{String => String}] each state's tone, empty without a lifecycle
          def tones(lifecycle)
            return {} unless lifecycle

            states = [lifecycle["default"], *lifecycle["transitions"].flat_map { |move| [*move["from"], move["to"]] }].uniq
            cycle = %w[ok info].cycle
            states.to_h { |state| [state, tone(state, lifecycle["default"], cycle)] }
          end

          # @return [String] the tone of one state; `cycle` hands out `ok` and `info` in turn
          def tone(state, default, cycle)
            return "neutral" if state == default

            STATES.include?(state.downcase) ? "danger" : cycle.next
          end

          # @return [Array<String>] the lower-case words of a CamelCase or snake_case name
          def words(name) = name.to_s.scan(/[A-Z][a-z0-9]*|[a-z0-9]+/).map(&:downcase)
        end
      end
    end
  end
end
