# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module Hecks
  module Adapters
    class MainIntegration
      # The record of the last commit of main a verification passed: one JSON file in the
      # repository's git directory, beside the quick-gate marker (`hecks-local-main-gate.json`),
      # holding the commit and the time. It is written whole to a temporary file and moved into
      # place, so a reader never meets half a file. Nothing but the verification of the next
      # landing reads it, to name the range of specs that landed since.
      module LastVerified
        # The file name, beside the other markers in the git directory.
        FILE = "hecks-last-verified-main.json"

        # @param common_dir [String] the repository's common git directory
        # @param sha [String] the commit a verification passed
        # @param at [Time] when it passed
        # @return [String] the path written
        def self.write(common_dir, sha, at: Time.now)
          path = File.join(common_dir, FILE)
          temporary = "#{path}.#{Process.pid}.tmp"
          File.write(temporary, JSON.generate("sha" => sha, "verdict" => "green", "at" => at.utc.iso8601))
          File.rename(temporary, path)
          path
        ensure
          FileUtils.rm_f(temporary) if temporary
        end

        # @param common_dir [String] the repository's common git directory
        # @return [Hash, nil] `sha`, `verdict` and `at`, or nil when none has been recorded
        def self.read(common_dir)
          path = File.join(common_dir, FILE)
          JSON.parse(File.read(path)) if File.exist?(path)
        rescue JSON::ParserError
          nil
        end
      end
    end
  end
end
