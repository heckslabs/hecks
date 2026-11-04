# frozen_string_literal: true

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
        # @param words [Array<String>] the command line's words
        # @return [Boolean] true for a question the setting lists under `reads_tap`
        def read_only?(launcher, words)
          return false unless launcher && words.first

          Array(launcher[:reads_tap]).map { |name| normal(name) }.include?(normal(words.first))
        end

        # A question's name as the command line spells it: lower case, dots for its separators.
        #
        # @param name [String] a question's name, bare or as the command line writes it
        # @return [String]
        def normal(name)
          bare = name.to_s.chomp("!").downcase
          bare.split(SEPARATORS).join(".")
        end
      end
    end
  end
end
