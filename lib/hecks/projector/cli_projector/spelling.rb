module Hecks
  module Projector
    module CliProjector
      # How the launcher spells an argument on the command line: the bare attribute name when a
      # value object has one field, the dotted path when it has several. It is the rule
      # `Adapters::Driving::Cli.expand` accepts, so help never teaches a word the launcher refuses.
      module Spelling
        module_function

        # The arguments with each sole leaf of a value object spelled as its attribute.
        #
        # @param arguments [Array<Hash>] projected leaf arguments, each with a dotted `:path`
        # @param siblings [Array<Hash>] other arguments the launcher also accepts, which count
        #   when deciding whether a leaf is alone under its attribute
        # @return [Array<Hash>] `arguments`, a sole leaf's `:path` replaced by the attribute name
        def spell(arguments, siblings = [])
          counts = (arguments + siblings).map { |argument| head(argument) }.tally
          arguments.map do |argument|
            alone = argument[:path].include?(".") && counts[head(argument)] == 1
            alone ? argument.merge(path: head(argument)) : argument
          end
        end

        # @param argument [Hash] a projected argument
        # @return [String] the first segment of its path
        def head(argument) = argument[:path].split(".").first
      end
    end
  end
end
