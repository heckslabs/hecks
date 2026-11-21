# frozen_string_literal: true

require "json"
require "fileutils"

module Hecks
  module Adapters
    # The bisect log of one repository: a JSON file in its common git directory that holds, for each
    # red Work item, how its red was searched. Landing reads it from any worktree, so one log serves
    # every session, and a spec's temporary repository never sees the owner's. The marker only
    # records and reports; whether a landing needs one is {BisectLogGuard}'s.
    class BisectLogMarker
      # The marker's file name, in the common git directory.
      FILE = "hecks-bisect-log.json"

      # @param git_dir [String] the repository's common git directory
      def initialize(git_dir)
        @path = File.join(git_dir, FILE)
      end

      # @param work [String] the red Work item's key
      # @return [Hash, nil] its entry (`kind`, `finding`, `quote`), or nil when none was recorded
      def read(work) = entries[work]

      # Records how a red was searched, replacing an earlier entry of the same Work item.
      #
      # @param work [String] the red Work item's key
      # @param kind [String] `bisect` (a search ran) or `obvious` (the failure made the fix plain)
      # @param finding [String] the culprit merge, `red at the base`, or why the failure is plain
      # @param quote [String] the failure line an obvious finding quotes
      # @return [Hash] the entry written
      def record!(work:, kind:, finding: "", quote: "")
        entry = { "kind" => kind, "finding" => finding, "quote" => quote }
        FileUtils.mkdir_p(File.dirname(@path))
        File.write(@path, JSON.generate(entries.merge(work => entry)))
        entry
      end

      private

      def entries
        File.exist?(@path) ? JSON.parse(File.read(@path)) : {}
      rescue JSON::ParserError
        {}
      end
    end
  end
end
