# frozen_string_literal: true

require "fileutils"

module Hecks
  module Adapters
    # Where the spool is and how far a drain has read it: the one place `SpoolFile` and
    # `SpoolCursorFile` agree on the spool's path and the sidecar beside it.
    #
    # The cursor is the number of spool lines already kept, counting blank and unreadable ones. It
    # lives in `<spool path>.cursor`, only moves forward, and is written by renaming a temporary
    # file over the sidecar. The spool itself is never written.
    class SpoolCursor
      # Where the hook appends, when the settings name no other path.
      DEFAULT_PATH = "~/.claude/hecks-dev/observations.spool"

      # The suffix of the sidecar that holds the cursor, beside the spool.
      SUFFIX = ".cursor"

      # @return [String] the spool file
      attr_reader :spool

      # @param settings [Hash] `path:` the spool file (default {DEFAULT_PATH})
      def initialize(settings = {})
        @spool = File.expand_path(settings[:path] || DEFAULT_PATH)
        @sidecar = "#{@spool}#{SUFFIX}"
      end

      # @return [Integer] the lines already kept; 0 when no cursor has been written
      # @raise [SystemCallError] when the sidecar exists and cannot be read
      def position
        File.file?(@sidecar) ? File.read(@sidecar).to_i : 0
      end

      # Moves the cursor to `count` when that is past where it is.
      #
      # @param count [Integer] the lines kept so far
      # @return [void]
      # @raise [SystemCallError] when the sidecar cannot be written
      def advance(count)
        return unless count > position

        FileUtils.mkdir_p(File.dirname(@sidecar))
        temporary = "#{@sidecar}.#{Process.pid}.tmp"
        File.write(temporary, "#{count}\n")
        File.rename(temporary, @sidecar)
      end
    end
  end
end
