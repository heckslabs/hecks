# frozen_string_literal: true

module Hecks
  module Adapters
    # The role a run starts or resumes as: the agent it names, else the role it works as when the
    # checkout holds that role's file in `.claude/agents`. A fill-started coder names no agent and
    # works as `coder`, so this is what loads `coder.md` and the model its frontmatter declares.
    # A `works_as` with no role file (`answerer`, `red-wake`) names no role.
    class RunRole
      # A role name safe to use as a file name under `.claude/agents`.
      NAME = /\A[a-z][a-z0-9_-]*\z/

      # @param held [Hash] the `AgentRun` record: `agent`, `works_as` and `repo`
      # @return [String, nil] the role, nil for none
      def self.of(held) = new(held).role

      # @param held [Hash] the `AgentRun` record
      def initialize(held)
        @held = held
      end

      # @return [String, nil] the named agent, else the role file's name, else nil
      def role
        named = plain(:agent).to_s
        return named unless named.empty?

        works = plain(:works_as).to_s
        works if works.match?(NAME) && File.file?(file(works))
      end

      private

      def file(works) = File.join(plain(:repo).to_s, ".claude", "agents", "#{works}.md")

      def plain(key) = @held[key].is_a?(Hash) ? @held[key][:value] : @held[key]
    end
  end
end
