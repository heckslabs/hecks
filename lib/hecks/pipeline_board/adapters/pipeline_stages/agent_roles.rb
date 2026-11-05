# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # The agent roles the board pins at its top: each role's name and how many of its sessions are
      # live. The roles come from the QualityControl world's `agent_roles` line. A session belongs to
      # a role when its name begins with the role's name.
      module AgentRoles
        module_function

        # @param registry [Runtime::Registry, nil]
        # @return [Array<String>] the declared role names, in declared order
        def declared(registry)
          names = world_settings(registry).fetch(:roles, "").to_s.split(",")
          names.map(&:strip).reject(&:empty?)
        end

        # @return [Hash] the `agent_roles` line of the QualityControl world, or nothing when it has none
        def world_settings(registry)
          return {} unless registry

          world = registry.world("QualityControl")
          world ? world.for_verb("agent_roles") : {}
        end

        # @param sessions [Array<Hash>, Hash] the board's sessions, or `{unknown:}`
        # @param names [Array<String>] the declared roles
        # @return [Array<Hash>, Hash] `name` and `live` for each role, or `{unknown:}`
        def of(sessions, names)
          return { unknown: "the sessions could not be read" } unless sessions.is_a?(Array)

          names.map do |name|
            live = sessions.count { |s| s[:name].to_s.start_with?(name) && %w[busy blocked].include?(s[:status]) }
            { name: name, live: live }
          end
        end
      end
    end
  end
end
