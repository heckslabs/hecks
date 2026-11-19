# frozen_string_literal: true

require_relative "started_work"

module Hecks
  module Adapters
    # Reads which other `AgentRun` serves the work a dispatch names, so the bluebook can decide
    # whether the work is already held, and, when given the {PinnedRoleHolders}, which other live
    # session holds the run's pinned role. It reports facts and decides nothing: the run's key, its
    # status and its agent.
    #
    # A run serves the Work item named by its `work` slug, or its own key when it names none (a
    # coder's run is keyed by its Work item). Every `AgentRun` is read on each dispatch.
    class WorkHolder
      # @return [#call, nil] the reader of the live session that holds a run's pinned role
      attr_reader :roles

      # @param registry [Runtime::Registry, nil] the booted registry; nil reads no runs
      # @param roles [#call, nil] the {PinnedRoleHolders} whose facts each answer carries too
      def initialize(registry, roles: nil)
        @registry = registry
        @roles = roles
      end

      # @param held [Hash] the dispatched `AgentRun` record: `run`, `work` and `agent`
      # @return [Hash{Symbol => String}] `holder:` the key of another run on the same work,
      #   `holder_status:` and `holder_agent:` its status and agent, and `requester_agent:` the
      #   dispatched run's agent; a started run is preferred when several serve the work, and the
      #   holder facts are empty when none does; and the {PinnedRoleHolders} facts, when it was
      #   given them
      def call(held)
        own = plain(held[:run]).to_s
        found = runs.reject { |run| value(run, :run) == own }.select { |run| served(run) == served(held) }
        { requester_agent: value(held, :agent) }.merge(facts(found.min_by { |run| started?(run) ? 0 : 1 }), role_facts(held))
      end

      # @return [Array<Object>] every `AgentRun` record the registry holds, none without one
      def runs
        aggregate = @registry&.bluebook("Hecks")&.aggregates
        aggregate = aggregate&.find { |candidate| candidate.hecks_name == "AgentRun" }
        aggregate ? @registry.repository("Hecks", aggregate).all : []
      end

      private

      def role_facts(held) = @roles ? @roles.call(held) : {}

      def facts(run)
        return { holder: "", holder_status: "", holder_agent: "" } unless run

        { holder: value(run, :run), holder_status: value(run, :status), holder_agent: value(run, :agent) }
      end

      def served(record) = value(record, :work).then { |work| work.empty? ? value(record, :run) : work }

      def started?(run) = value(run, :status) == "started"

      def value(record, name) = plain(StartedWork.value(record, name)).to_s

      def plain(value) = value.is_a?(Hash) ? value[:value] : value
    end
  end
end
