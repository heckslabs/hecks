# frozen_string_literal: true

require_relative "launcher_options"

module Hecks
  module Adapters
    module Driving
      # Tells the launcher which questions read the event tap, so it answers them on a boot that
      # writes nothing. The bluebook's `launcher` setting lists them under `reads_tap`.
      module ReadOnlyQuestion
        # The separators between a question's bluebook, aggregate and own name.
        SEPARATORS = /[.:]+/

        module_function

        # @param launcher [Hash, nil] the bluebook's `launcher` setting
        # @param words [Array<String>] the command line's words; the question is the first, or the
        #   second when the first names a domain (`pipeline_board PipelineBoard.snapshot`)
        # @return [Boolean] true for a question the setting lists under `reads_tap`
        def read_only?(launcher, words)
          return false unless launcher && words.first

          listed = Array(launcher[:reads_tap]).map { |name| normal(name) }
          words.first(2).any? { |word| listed.include?(normal(word)) }
        end

        # Whether the line a launcher was given asks a question its bluebook lists under
        # `reads_tap`, which the launcher answers on a boot that writes nothing: no outbox row
        # is redriven and no saga resumed.
        #
        # @param described [#registry] the described domain the line is run against
        # @param argv [Array<String>] the command line's words
        # @param bluebook [String] the bluebook the line speaks to
        # @return [Boolean] true for a question that boots read-only
        def for_line?(described, argv, bluebook)
          read_only?(LauncherOptions.settings(described, bluebook), argv)
        end

        # A question's name as the command line spells it: lower case, dots for its separators,
        # and no underscores, so `pipeline_board.snapshot` and `PipelineBoard.Snapshot` agree.
        #
        # @param name [String] a question's name, bare or as the command line writes it
        # @return [String]
        def normal(name)
          bare = name.to_s.chomp("!").downcase
          bare.delete("_").split(SEPARATORS).join(".")
        end
      end
    end
  end
end
