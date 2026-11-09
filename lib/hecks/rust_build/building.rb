# frozen_string_literal: true

require "open3"
require_relative "session_build"
require_relative "build_lock"

module Hecks
  module RustBuild
    # How a build whose output is held is started: under the build lock, with the job cap and
    # `nice` of the Tickets world's `rust_build` line and the target directory of its
    # `session_environment` line. Included into `RustBuild`'s singleton, so
    # `RustBuild.capture_build` is what the tools call.
    module Building
      # Runs a build and holds what it printed, under the build lock, the job cap and `nice`.
      #
      # @param command [Array<String>] the program and its arguments
      # @param chdir [String] the directory to run it in
      # @param binary [Boolean] whether the binary it builds is run afterwards, which takes the
      #   worktree's own target directory
      # @param env [Hash{String => String}] variables to set for it
      # @return [Array(String, Process::Status)] its output and how it ended
      def capture_build(command, chdir:, binary: false, env: {})
        root = SessionBuild.root_of(chdir)
        BuildLock.building(command) do |held|
          settings = held.merge(SessionBuild.environment(root: root, binary: binary)).merge(env)
          Open3.capture2e(settings, *SessionBuild.command(command, root: root), chdir: chdir)
        end
      end

      private

      # @return [Boolean] whether the program ended well
      def spawn_build(held, env, command, root, options)
        settings = held.merge(SessionBuild.environment(root: root)).merge(env)
        system(settings, *SessionBuild.command(command, root: root), **options)
      end
    end
  end
end
