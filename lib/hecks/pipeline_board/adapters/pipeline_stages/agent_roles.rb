# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # The agent roles the board pins at its top: each role's name and how many of its sessions are
      # live. The roles come from the Hecks world's `agent_roles` line. A session belongs to
      # a role when its name begins with the role's name.
      module AgentRoles
        module_function

        # @param registry [Runtime::Registry, nil]
        # @return [Array<String>] the declared role names, in declared order
        def declared(registry)
          names = world_settings(registry).fetch(:roles, "").to_s.split(",")
          names.map(&:strip).reject(&:empty?)
        end

        # @return [Hash] the `agent_roles` line of the Hecks world, or nothing when it has none
        def world_settings(registry)
          return {} unless registry

          world = registry.world("Hecks")
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

        # The architect's plan reviews, as the launcher reads them in the checkout that holds the
        # live store, when the board is told where that is (PIPELINE_BOARD_LAUNCHER_ROOT).
        #
        # @return [Array<Hash>, Hash] each review's `work`, `verdict`, `findings`; or `{unknown:}`
        def reviews
          launched("PlanReview.reviews") do |row|
            { work: row["work"].to_s, verdict: row["verdict"].to_s, findings: row["findings"].to_s }
          end
        end

        # The promotions the release manager recommends that the owner has not settled.
        #
        # @return [Array<Hash>, Hash] each recommendation's `change` and `reasons`, or `{unknown:}`
        def recommendations
          launched("PromotionRecommendation.open") do |row|
            { change: row["change"].to_s, reasons: row["reasons"].to_s }
          end
        end

        # @param query [String] an Agents query, as the launcher names it
        # @yieldparam row [Hash] one answer row
        # @return [Array<Hash>, Hash] the block's result for each row, or `{unknown:}`
        def launched(query, &)
          root = ENV.fetch("PIPELINE_BOARD_LAUNCHER_ROOT", "")
          return [] if root.empty?

          Probe.json("exe/hecks", "agents", query, chdir: root).map(&)
        rescue Unavailable => e
          { unknown: e.message }
        end
      end
    end
  end
end
