require_relative "agent"
require_relative "assistant"
require_relative "panels"
require_relative "session"

module Hecks
  module Composer
    # Everything the editor keeps for one workspace, on the hecksagon side: the draft bookkeeping,
    # the agent that edits it and the panels beneath the editor. Opening another domain builds a
    # new workbench, so nothing of the old workspace carries over.
    class Workbench
      # The registry of one agent adapter: the real `claude`, or a scripted `fake`.
      #
      # @param name [String, nil] `claude` (the default) or `fake`
      # @return [Runtime::Registry] a registry holding the `composer_agent` port and that adapter
      def self.agents_named(name)
        adapter = name == "fake" ? "fake_agent" : "claude_composer"
        require_relative "adapters/#{adapter}"
        Agent.registry_with(File.join(Agent::ADAPTERS, "#{adapter}.adapter"))
      end

      # @return [String] the domain directory this workbench is for
      attr_reader :workspace

      # @param workspace [String] the domain directory
      # @param agents [Runtime::Registry, nil] a registry holding the `composer_agent` port and one
      #   adapter; the real `claude` one when nil
      def initialize(workspace:, agents: nil)
        @workspace = File.expand_path(workspace)
        @agents = agents
      end

      # @return [String] the workspace's directory name, which names its draft
      def slug = File.basename(workspace)

      # @return [Session] the draft bookkeeping, booted on first use
      def session = @session ||= Session.new

      # @return [Assistant] the agent loop over this workspace
      def assistant = @assistant ||= Assistant.new(workspace: workspace, agents: agents, session: session)

      # @return [Panels] what answers the lower panels
      def panels = @panels ||= Panels.new(workspace: workspace, session: session)

      # Releases what the panels booted.
      # @return [void]
      def close = @panels&.close

      private

      def agents = @agents ||= self.class.agents_named("claude")
    end
  end
end
