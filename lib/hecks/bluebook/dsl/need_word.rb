module Hecks
  module Bluebook
    module DSL
      # The `needs` word, shared by the builders of the two declarations that may use it: a
      # command and a query (ADR 0081). The including builder holds `@name` and `@needs` (an
      # empty list) and answers `attributes`.
      module NeedWord
        # The outside facts a declaration may need, each the name of the attribute the runtime
        # fills when the caller leaves it out. `now` is the clock port's reading in epoch seconds;
        # `today` is the day it falls in, whole days since the epoch in UTC.
        NEEDABLE_FACTS = %i[now today].freeze

        # Declares an outside fact the runtime supplies before any given or filter runs:
        # `needs :now` fills the declaration's own `now` attribute from the clock port when the
        # caller names none.
        #
        # @param fact [Symbol] one of `NEEDABLE_FACTS`
        # @return [Array<Symbol>] the facts declared so far
        # @raise [Bluebook::DSL::Malformed] if the fact is not one the runtime can supply, or is
        #   declared twice
        def needs_impl(fact)
          fact = fact.to_sym
          unless NEEDABLE_FACTS.include?(fact)
            raise Malformed,
                  "#{@name} needs :#{fact}, which the runtime cannot supply — it supplies " \
                  "#{NEEDABLE_FACTS.map { |known| ":#{known}" }.join(', ')}"
          end
          raise Malformed, "#{@name} declares needs :#{fact} twice" if @needs.include?(fact)

          @needs << fact
        end

        private

        # A fact is filled into the argument of the same name, so the declaration has one.
        #
        # @raise [Bluebook::DSL::Malformed] if a needed fact has no attribute to fill
        def refuse_undeclared_needs!
          declared = attributes.map { |attribute| attribute.name.to_s }
          missing  = @needs.reject { |fact| declared.include?(fact.to_s) }
          return if missing.empty?

          raise Malformed,
                "#{@name} needs :#{missing.first} but declares no attribute :#{missing.first} " \
                "for the runtime to fill — add `attribute :#{missing.first}, <type>`"
        end
      end
    end
  end
end
