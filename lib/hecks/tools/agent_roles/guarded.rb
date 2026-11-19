# frozen_string_literal: true

require "fileutils"

module Hecks
  module Tools
    module AgentRoles
      # The list of guarded roles, one role a line under a generated-file banner: each role that has
      # `RoutingRule` rows. The Bash guard hook reads it when `Role.guard` cannot answer, so it
      # knows whom to refuse without booting Hecks; it writes the list, or compares it.
      class Guarded
        # The first line of the list, marking it as projected.
        BANNER = "# Generated from agents.bluebook, do not edit"

        # @param path [String] the file holding the list
        # @param roles [Array<String>] the roles that have routing rows
        def initialize(path, roles)
          @path = path
          @roles = roles
        end

        # @return [String] the text the file should hold
        def text = [BANNER, *@roles.uniq].join("\n").then { |body| "#{body}\n" }

        # @return [Boolean] whether the file holds the text
        def current? = File.exist?(@path) && File.read(@path) == text

        # Compares and writes nothing.
        #
        # @return [Integer] 0 when the list is current, otherwise 1
        def check
          return 0 if current?

          warn "agent_roles: out of date: #{File.basename(@path)} (run hecks regeneration_run.project_agent_roles!)"
          1
        end

        # Writes the list when it is stale.
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
