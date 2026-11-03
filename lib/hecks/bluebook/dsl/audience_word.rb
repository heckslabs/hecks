require "hecks/vocabulary"

module Hecks
  module Bluebook
    module DSL
      # The `audience` word of a command: who a launcher lists it for (ADR 0163). It decides
      # listing only; the role still decides who may run the command. The including builder holds
      # `@name`.
      module AudienceWord
        # The audiences a command may be listed for: a person at a keyboard, an agent through the
        # MCP door, a CI step, or the run's own bookkeeping.
        AUDIENCES = Hecks::Vocabulary.fetch("CommandAudience")

        # Names who a launcher lists the command for.
        #
        # @param values [Array<Symbol, String>] one or several of `AUDIENCES`
        # @return [Array<String>] the audience as stored
        # @raise [Bluebook::DSL::Malformed] if one is already declared, one is not an audience, or
        #   one is named twice
        def audience_impl(*values)
          names = values.map(&:to_s)
          raise Malformed, "#{@name} declares its audience twice" if @audience
          raise Malformed, audience_problem(names) if audience_problem(names)

          @audience = names
        end

        private

        # Why an audience declaration is refused, or nil when every name is an audience named once.
        def audience_problem(names)
          return "#{@name} names no audience" if names.empty?

          unknown = names - AUDIENCES
          return "#{@name} names #{unknown.join(", ")} as an audience; the audiences are #{AUDIENCES.join(", ")}" if unknown.any?

          "#{@name} names an audience twice" if names.uniq.size != names.size
        end
      end
    end
  end
end
