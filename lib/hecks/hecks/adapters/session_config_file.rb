# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "hecks/cache_dir"

module Hecks
  module Adapters
    # The MCP configuration a role session is started with, kept in a file only its owner can read.
    # `claude --mcp-config` takes a path as well as a string, and a path is all `ps` shows of it,
    # where the string would show every server's command line and environment to every user of the
    # machine. The file is named for the run and removed with the session; any left by a session
    # nobody removed goes after a fortnight.
    class SessionConfigFile
      # How long a configuration nobody removed stays.
      KEEP_SECONDS = 14 * 24 * 60 * 60

      # What a run's key may not put in a file name.
      UNSAFE_IN_NAME = /[^\w.-]/

      # @param directory [String, nil] where the files live; a private directory under the cache
      #   root when none is given
      def initialize(directory: nil)
        @directory = directory
      end

      # Writes the configuration for a run, replacing an earlier one for the same run.
      #
      # @param config [Hash] the configuration
      # @param run [String, nil] the run it is for; a one-off name when none is given
      # @return [String] the path to pass to `--mcp-config`
      def write(config, run)
        FileUtils.mkdir_p(directory, mode: 0o700)
        sweep
        path = File.join(directory, "#{slug(run)}.json")
        File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.generate(config)) }
        path
      end

      # Removes a run's configuration, when it has one.
      #
      # @param run [String] the run
      # @return [void]
      def discard(run)
        File.delete(File.join(directory, "#{slug(run)}.json"))
      rescue SystemCallError
        nil
      end

      private

      def directory = (@directory ||= Hecks::CacheDir.path("session_mcp"))

      def slug(run) = run.to_s.empty? ? "session-#{SecureRandom.hex(6)}" : run.to_s.gsub(UNSAFE_IN_NAME, "_")

      def sweep
        cutoff = Time.now - KEEP_SECONDS
        Dir.glob(File.join(directory, "*.json")).each { |file| File.delete(file) if File.mtime(file) < cutoff }
      rescue SystemCallError
        nil
      end
    end
  end
end
