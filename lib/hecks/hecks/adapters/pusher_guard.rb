# frozen_string_literal: true

require_relative "pusher_marker"
require_relative "console_capture"

module Hecks
  module Adapters
    # What the assigned pusher refuses: a boarding of the push train by any session but the pusher.
    # A repository with no pusher assigned is not locked, so a fresh clone boards as before. The
    # refusal names the pusher: `only the pusher boards: <id>`.
    class PusherGuard
      # The sentence every refusal opens with, which the `Pusher` bluebook's policy listens for.
      REFUSAL = "only the pusher boards"

      # @param git_dir [String] the repository's common git directory
      # @param env [Hash] the environment the caller's identity is read from
      def initialize(git_dir, env: ENV)
        @marker = PusherMarker.new(git_dir)
        @env = env
      end

      # @return [void]
      # @raise [ConsoleCapture::Failure] when a pusher is assigned and the caller is not it
      def boarding!
        pusher = @marker.read
        return if pusher.nil? || pusher.empty? || pusher == PusherMarker.caller_id(@env)

        raise ConsoleCapture::Failure, "#{REFUSAL}: #{pusher}"
      end
    end
  end
end
