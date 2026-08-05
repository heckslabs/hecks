require_relative "command_rules/admissibility"
require_relative "command_rules/references"
require_relative "command_rules/arithmetic"
require_relative "command_rules/emission"
require_relative "command_rules/authorization"

module Hecksagain
  module Runtime
    # The rules both interpreters consult, one concern per file beside
    # this one: whether a command may run (admissibility), whether its
    # references point at anything (references), what its arithmetic
    # mutations mean (arithmetic), what its emits become (emission), and
    # whether the caller may run it at all (authorization).
    class CommandRules
      include Admissibility
      include References
      include Arithmetic
      include Emission
      include Authorization

      attr_reader :registry

      def initialize(registry)
        @registry = registry
      end
    end
  end
end
