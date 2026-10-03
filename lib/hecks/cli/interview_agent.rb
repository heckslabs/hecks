require_relative "../runtime/registry"
require_relative "../ports/agent"

module Hecks
  module CLI
    # The interviewer an interview session talks to: the agent port, resolved against a registry
    # that holds one adapter (ADR 0088). The session never sees the adapter, only validated
    # questions and proposals, so a spec can stand a scripted adapter in for the real one.
    class InterviewAgent
      PORT = File.expand_path("../ports/agent.port", __dir__)
      CLAUDE_CODE = File.expand_path("../adapters/driven/claude_code.adapter", __dir__)

      # The agent a real interview uses: the developer's own `claude`, no key or model of hecks's.
      #
      # @return [InterviewAgent] one resolved against the Claude Code adapter
      def self.claude
        require_relative "../adapters/driven/claude_code"
        new(registry_with(CLAUDE_CODE))
      end

      # @param adapter_files [Array<String>] adapter declarations to load beside the agent port
      # @return [Runtime::Registry] a registry in which exactly those adapters implement the port
      def self.registry_with(*adapter_files)
        registry = Runtime::Registry.new
        Hecks.with_registry(registry) do
          Kernel.load(PORT)
          adapter_files.each { |file| Kernel.load(file) }
        end
        registry
      end

      # @return [Boolean] whether a `claude` executable is on the path, so the AI can be tried
      def self.claude_available?
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, "claude")) }
      end

      # @param registry [Runtime::Registry] a registry with the agent port and one adapter for it
      def initialize(registry)
        @registry = registry
      end

      # @param state [Hash] the interview so far, as the session describes it
      # @param asked [Array<String>] the questions already asked
      # @return [Ports::Agent::Question, nil] the next question, or nil if the adapter offered none
      # @raise [Ports::Agent::Unavailable, Ports::Agent::ValidationError] when it could not answer
      def question(state:, asked:)
        Ports::Agent.ask(@registry, state: state, asked: asked).first
      end

      # @param prose [String] what the expert just said, as the developer typed it
      # @param state [Hash] the interview so far
      # @return [Array<Ports::Agent::Proposal>] the findings the sentence names; none for a question
      # @raise [Ports::Agent::Unavailable, Ports::Agent::ValidationError] when it could not answer
      def proposals(prose:, state:)
        Ports::Agent.interpret(@registry, prose: prose, state: state)
      end
    end
  end
end
