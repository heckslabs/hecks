# frozen_string_literal: true

require "time"
require_relative "shell"
require_relative "console_capture"

module Hecks
  module Adapters
    # The `Sessions` port's adapter for `PlainSession`: removes a session the board started by hand
    # with `claude rm`, once the bluebook has allowed the removal.
    #
    # It decides nothing. Whether a session is finished and waits on nobody is the bluebook's rule;
    # this only runs the removal. The command is an argument list, never a string for a shell.
    class ClaudeSessions
      # The command that removes sessions.
      COMMAND = "claude"

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @shell = Shell.new
      end

      # Removes one session with `claude rm`.
      #
      # @param session [Hash, String] the session's id
      # @return [Hash{Symbol => Hash}] `removed_at:` when it was removed, as an ISO 8601 string
      # @raise [ConsoleCapture::Failure] when the command refuses
      def discard(session:)
        id = plain(session)
        result = @shell.capture(COMMAND, "rm", id)
        raise ConsoleCapture::Failure, "#{COMMAND} rm #{id} refused: #{result.err.strip}" unless result.ok?

        { removed_at: { value: Time.now.utc.iso8601 } }
      end

      private

      def plain(value) = value.is_a?(Hash) ? value.transform_keys(&:to_s)["value"].to_s : value.to_s
    end
  end
end
