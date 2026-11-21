# frozen_string_literal: true

require_relative "bisect_log_marker"
require_relative "console_capture"

module Hecks
  module Adapters
    # What a red train's or a red main's fix must show before it lands: how its red was searched. A
    # branch named for such a Work item lands only when the repository's bisect log holds an entry
    # for it, a search or an obvious-from-the-failure finding that quotes the failure line.
    class BisectLogGuard
      # The Work item keys whose fix is held to a bisect.
      RED_ITEMS = %w[red-train- red-main].freeze

      # A branch lead the QA loop adds to a Work item's name.
      QA_LEAD = "qa/"

      # @param branch [String] a branch name, with or without the QA lead
      # @return [Boolean] whether the branch is named for a red train's or a red main's Work item
      def self.guarded?(branch) = RED_ITEMS.any? { |lead| branch.to_s.delete_prefix(QA_LEAD).start_with?(lead) }

      # @param git_dir [String] the repository's common git directory
      def initialize(git_dir)
        @marker = BisectLogMarker.new(git_dir)
      end

      # @param branch [String] the branch about to land on main
      # @return [void]
      # @raise [ConsoleCapture::Failure] naming the missing bisect when the branch is guarded and
      #   its Work item has no usable log entry
      def landing!(branch)
        return unless self.class.guarded?(branch)

        work = branch.delete_prefix(QA_LEAD)
        return if usable?(@marker.read(work))

        raise ConsoleCapture::Failure, "#{work} has no bisect log: record one (exe/hecks Integration.probe! " \
                                       "for each failing example) or an obvious-from-the-failure finding " \
                                       "(exe/hecks BisectLog.log! kind.value=obvious quote.value=<failure line>)"
      end

      private

      def usable?(entry) = !entry.nil? && (entry["kind"] != "obvious" || !entry["quote"].to_s.strip.empty?)
    end
  end
end
