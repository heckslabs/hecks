# frozen_string_literal: true

require "json"

module Hecks
  module Adapters
    class ClaudeCleaning
      # Removes the sessions no run holds: the owner's own conversations, started by hand.
      #
      # A session is removed when it is done or stopped, its transcript was last written more than
      # `keep` hours ago and it holds no worktree. One that is working or blocked on the owner, one
      # whose worktree still stands, and a pinned role's are kept and named; a session that is
      # merely recent is kept without a name. It uses `claude rm` only: never `claude stop`, never a
      # kill. Removal drops the session from the list; its transcript stays under
      # `~/.claude/projects`.
      class PlainSweep
        # The listing states that mean the session has ended.
        ENDED = %w[done stopped].freeze

        # The reason of a session kept without being named: it ended less than `keep` hours ago.
        RECENT = "recent"

        # The result of one sweep.
        #
        # @!attribute [r] removed
        #   @return [Array<String>] the names of the sessions removed
        # @!attribute [r] kept
        #   @return [Array<Array(String, String)>] each session kept by name, with the reason
        Result = Struct.new(:removed, :kept)

        # @param keep_hours [Numeric] how long a finished session stays listed
        # @param now [#call] answers the time
        # @param transcript [ClaudeTranscript] says where a session worked and when it last wrote
        # @param remove [#call] takes a session's short id and returns nil, or why it was refused
        # @param pinned [Array<String>] the roles whose session is never removed
        def initialize(keep_hours:, now:, transcript:, remove:, pinned: [])
          @keep = keep_hours.to_f * 3600
          @now = now
          @transcript = transcript
          @remove = remove
          @pinned = pinned
        end

        # @param entries [Array<Hash>] the sessions of the `claude agents` listing
        # @param bound [Array<String>] the ids of the sessions a dispatched run holds
        # @return [Result]
        def call(entries, bound)
          result = Result.new([], [])
          entries.reject { |entry| bound.include?(entry["id"]) || bound.include?(entry["sessionId"]) }
                 .each { |entry| judge(entry, result) }
          result
        end

        private

        def judge(entry, result)
          name = entry["name"].to_s.empty? ? entry["id"].to_s : entry["name"].to_s
          why = reason(entry) || @remove.call(entry["id"])
          return result.removed << name unless why

          result.kept << [name, why] unless why == RECENT
        end

        # @return [String, nil] why the session is kept, nil when it goes
        def reason(entry)
          return "working or blocked on the owner" unless ENDED.include?(entry["state"].to_s)
          return "pinned role" if @pinned.any? { |role| entry["name"].to_s.start_with?(role) }

          held(entry["sessionId"].to_s)
        end

        def held(full)
          path = @transcript.worktree(full).to_s
          return "worktree #{path} still stands" if !path.empty? && File.directory?(path)

          old?(full) ? nil : RECENT
        rescue SystemCallError, JSON::ParserError
          "transcript cannot be read"
        end

        def old?(full) = @now.call - @transcript.modified_at(full) > @keep
      end
    end
  end
end
