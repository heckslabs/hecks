require_relative "../ports/clock"

module Hecks
  module Runtime
    # Answers the outside facts a command or a query `needs` (ADR 0081). A fact is answered once,
    # before any given or filter reads the arguments, and the answer rides in the declaration's own
    # arguments, so an event records it and a replay re-dispatches the recorded value rather than
    # asking again.
    module Needs
      # What answers each fact a declaration may need: `now` is the clock port's reading in epoch
      # seconds, `today` the day it falls in, whole days since the epoch in UTC.
      ANSWERS = {
        now:   ->(registry) { Ports::Clock.now(registry) },
        today: ->(registry) { Ports::Clock.now(registry) / 86_400 }
      }.freeze

      module_function

      # Fills each outside fact the declaration `needs` and the caller left out. A value the caller
      # supplied is kept, so a test or a back-fill can name its own time.
      #
      # @param declaring [#needs, #attributes] the command or query being run
      # @param args [Hash{Symbol => Object}] the arguments the caller passed
      # @param registry [Runtime::Registry] where the clock port is bound
      # @return [Hash{Symbol => Object}] `args`, with each missing needed fact answered
      # @raise [Runtime::WiringError] when the port that answers a fact is not bound exactly once
      def fill(declaring, args, registry:)
        missing = declaring.needs.reject { |fact| args.key?(fact) || args.key?(fact.to_s) }
        return args if missing.empty?

        args.merge(missing.to_h { |fact| [fact, value(declaring, fact, registry)] })
      end

      # The answer to one fact, in the shape the declaration's argument of that name takes: a bare
      # Integer for an Integer attribute, else the one-field value object the language declares.
      #
      # @param declaring [#attributes] the command or query
      # @param fact [Symbol] a key of `ANSWERS`
      # @param registry [Runtime::Registry] where the clock port is bound
      # @return [Integer, Hash{Symbol => Integer}] the answer, shaped for its argument
      def value(declaring, fact, registry)
        answer    = ANSWERS.fetch(fact).call(registry)
        attribute = declaring.attributes.find { |held| held.name.to_s == fact.to_s }
        attribute&.type.to_s == "Integer" ? answer : { value: answer }
      end
    end
  end
end
