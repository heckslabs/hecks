# frozen_string_literal: true

require "json"
require "open3"
require_relative "supervisor"

module Hecks
  module Harness
    # The crew's roles, opened as Harness sessions. Each role's file, `.claude/agents/<role>.md`,
    # is read by `hecks-harness role`: the session's brief, the tools the supervisor lets it use
    # beside `send_message`, and its model.
    module Roles
      # The checkout whose role files are read.
      ROOT = File.expand_path("../../..", __dir__)

      # The roles' files, relative to the checkout.
      AGENTS = ".claude/agents"

      # A role as its session holds it.
      Role = Data.define(:brief, :tools, :model)

      # The role cannot be read, or is not opened in a harness run.
      class Unbriefed < StandardError; end

      module_function

      # @param root [String] the checkout
      # @return [Array<String>] every role with a file under `.claude/agents`, sorted
      def names(root: ROOT) = Dir.glob(File.join(root, AGENTS, "*.md")).map { |path| File.basename(path, ".md") }.sort

      # @param role [String] a role with a file under `.claude/agents`, such as "staff-engineer"
      # @param root [String] the checkout
      # @param binary [String] the `hecks-harness` binary that reads it
      # @return [Role] the role's brief, its tools and its model
      # @raise [Unbriefed] when the role has no file, the binary cannot read it, or the role is an
      #   owner's, started by hand with every tool
      def role(role, root: ROOT, binary: Supervisor::BINARY)
        path = File.join(root, AGENTS, "#{role}.md")
        raise Unbriefed, "no role file for #{role} at #{path}" unless File.file?(path)

        text, error, status = Open3.capture3(binary, "role", path)
        raise Unbriefed, error.strip unless status.success?

        Role.new(**JSON.parse(text, symbolize_names: true))
      end

      # @param role [String] a role with a file under `.claude/agents`
      # @return [String] the brief a session opened for that role is given
      # @raise [Unbriefed] as {role} does
      def brief(role, root: ROOT, binary: Supervisor::BINARY) = role(role, root: root, binary: binary).brief
    end
  end
end
