module Hecks
  module Adapters
    # Names a started session in the environment it runs in, so every launcher line the session
    # runs says in the usage log who ran it. The name is the run and its role, nothing the run was
    # asked to do: no argument, path or brief goes into it. It also exports the run, role and work
    # item, which the commit-msg hook writes into each commit's trailers.
    module SessionCaller
      # The variable the usage log reads the caller from.
      VARIABLE = "HECKS_CALLER".freeze
      # The most characters a name keeps.
      LONGEST = 64
      # The variables the commit-msg hook reads the run, its role and its work item from.
      TRAILER_VARIABLES = { run: "HECKS_RUN_KEY", agent: "HECKS_ROLE", work: "HECKS_WORK" }.freeze
      # What a name may not carry: anything but letters, digits and `_.:/-`.
      UNSAFE_CHARACTERS = %r{[^\w.:/-]}

      module_function

      # @param environment [Hash{String => String}] what every session starts with
      # @param held [Hash] the `AgentRun` record: `run` and, when one is named, `agent`
      # @return [Hash{String => String}] the environment with the session's name added
      def environment(environment, held)
        name = name(held)
        named = name.empty? ? environment : environment.merge(VARIABLE => name)
        named.merge(trailer_environment(held))
      end

      # @param held [Hash] the `AgentRun` record
      # @return [Hash{String => String}] the trailer variables of the fields the record names
      def trailer_environment(held)
        TRAILER_VARIABLES.each_with_object({}) do |(field, variable), found|
          text = value(held[field]).strip
          found[variable] = text unless text.empty?
        end
      end

      # @return [String] `role:run`, or the run alone when no role is named
      def name(held)
        parts = %i[agent run].map { |field| value(held[field]) }.reject(&:empty?)
        parts.join(":").gsub(UNSAFE_CHARACTERS, "")[0, LONGEST]
      end

      # @return [String] a held value, which may arrive wrapped as `{ value: x }`
      def value(held) = (held.is_a?(Hash) ? held[:value] : held).to_s
    end
  end
end
