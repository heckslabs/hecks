# frozen_string_literal: true

require "open3"
require_relative "supervisor"

module Hecks
  module Harness
    # The crew's roles, opened as Harness sessions: each session's brief is its role file,
    # `.claude/agents/<role>.md`, turned into a brief by `hecks-harness brief`.
    module Roles
      # The checkout whose role files are read.
      ROOT = File.expand_path("../../..", __dir__)

      # The roles' files, relative to the checkout.
      AGENTS = ".claude/agents"

      # The brief cannot be read.
      class Unbriefed < StandardError; end

      module_function

      # @param role [String] a role with a file under `.claude/agents`, such as "staff-engineer"
      # @param root [String] the checkout
      # @param binary [String] the `hecks-harness` binary that writes the brief
      # @return [String] the brief a session opened for that role is given
      # @raise [Unbriefed] when the role has no file, or the binary cannot read it
      def brief(role, root: ROOT, binary: Supervisor::BINARY)
        path = File.join(root, AGENTS, "#{role}.md")
        raise Unbriefed, "no role file for #{role} at #{path}" unless File.file?(path)

        text, error, status = Open3.capture3(binary, "brief", path)
        status.success? ? text : raise(Unbriefed, error.strip)
      end
    end
  end
end
