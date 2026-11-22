# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"

module Hecks
  module Tools
    module AgentRoles
      # The rules file the Bash guard hook decides from without asking `Role.guard`: for each role
      # with `RoutingRule` rows, the `git` and `gh` rows it may run exactly, under the digest of the
      # Agents bluebooks they came from. The hook trusts the file only while that digest still
      # matches the bluebooks in its checkout; it writes the file, or compares it.
      class GuardRules
        # The call words a row must start with to be a static `git` or `gh` read.
        SHELL = /\A(?:git|gh) /

        # @param agents [String] the folder holding the Agents bluebooks
        # @return [String] the SHA-256 of the folder's `*.bluebook` files, joined in name order
        def self.digest(agents) = Digest::SHA256.hexdigest(sources(agents).map { |path| File.read(path) }.join)

        # @return [Array<String>] the paths of the folder's `*.bluebook` files, in name order
        def self.sources(agents) = Dir.glob(File.join(agents, "*.bluebook"))

        # @param path [String] the file holding the rules
        # @param agents [String] the folder holding the Agents bluebooks
        # @param commands [Hash{String => Array<String>}] each role's routing patterns
        def initialize(path, agents, commands)
          @path = path
          @agents = agents
          @commands = commands
        end

        # @return [String] the text the file should hold
        def text
          roles = @commands.transform_values { |patterns| patterns.grep(SHELL).reject { |row| row.include?("*") } }
          "#{JSON.pretty_generate(digest: self.class.digest(@agents), roles: roles)}\n"
        end

        # @return [Boolean] whether the file holds the text
        def current? = File.exist?(@path) && File.read(@path) == text

        # Compares and writes nothing.
        #
        # @return [Integer] 0 when the file is current, otherwise 1
        def check
          return 0 if current?

          warn "agent_roles: out of date: #{File.basename(@path)} (run hecks regeneration_run.project_agent_roles!)"
          1
        end

        # Writes the file when it is stale.
        #
        # @return [Integer] 0
        def write
          return 0 if current?

          FileUtils.mkdir_p(File.dirname(@path))
          File.write(@path, text)
          puts "wrote #{File.basename(@path)}"
          0
        end
      end
    end
  end
end
