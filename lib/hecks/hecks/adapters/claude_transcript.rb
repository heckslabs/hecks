# frozen_string_literal: true

require "json"

module Hecks
  module Adapters
    # Reads a background session's transcript file and says whether a person spoke in it after the
    # brief.
    #
    # It reports a fact and judges nothing: `AgentRun` decides what a taken-over session means. When
    # the transcript cannot be found or read the answer is "taken over", because the caller removes
    # a session only on a clear "no".
    class ClaudeTranscript
      # The directory, under the home directory, the transcripts are kept in, one per project.
      PROJECTS = File.join(".claude", "projects")

      # Text a session writes into its own transcript as a user entry without a person typing it.
      AUTOMATIC_TEXT = /\A\s*<(task-notification|system-reminder|command-(name|message)|local-command-|bash-)/

      # What the pipeline puts at the head of an answer it sends to a session, so the transcript
      # tells that turn from a person typing. {ClaudeResumption} writes it.
      PIPELINE_MARK = "[pipeline answer] "

      # @param projects [String] the directory holding the per-project transcript folders
      def initialize(projects: File.join(Dir.home, PROJECTS))
        @projects = projects
      end

      # @param session_id [String] the full session id, which names the transcript file
      # @return [Boolean] true when a person replied after the brief, or when this cannot be told
      def taken_over?(session_id)
        found = reading(session_id)
        found[:state] != :read || found[:person_turns].positive?
      end

      # How the transcript read and how many turns a person typed after the brief; the pipeline's
      # own answers (see {PIPELINE_MARK}) and automatic entries are not counted.
      #
      # @param session_id [String] the full session id, which names the transcript file
      # @return [Hash{Symbol => Object}] `state:` `:read`, `:missing` or `:unreadable`, and
      #   `person_turns:` the count (0 unless the transcript was read)
      def reading(session_id)
        path = Dir.glob(File.join(@projects, "*", "#{session_id}.jsonl")).first
        return { state: :missing, person_turns: 0 } unless path && !session_id.to_s.empty?

        { state: :read, person_turns: [human_messages(path).length - 1, 0].max }
      rescue SystemCallError, JSON::ParserError
        { state: :unreadable, person_turns: 0 }
      end

      # @param session_id [String] the full session id, which names the transcript file
      # @return [Time] when the transcript was last written
      # @raise [SystemCallError] when the transcript cannot be found
      def modified_at(session_id)
        path = Dir.glob(File.join(@projects, "*", "#{session_id}.jsonl")).first
        raise Errno::ENOENT, "no transcript for session #{session_id}" unless path && !session_id.to_s.empty?

        File.mtime(path)
      end

      # Where the session's own worktree is: the path its transcript last recorded when it entered a
      # worktree, which is not the directory `claude agents` reports.
      #
      # @param session_id [String] the full session id, which names the transcript file
      # @return [String, nil] the worktree path, or nil when the session never entered a worktree
      #   or left it
      # @raise [SystemCallError] when the transcript cannot be found or read
      # @raise [JSON::ParserError] when the transcript is not JSON lines
      def worktree(session_id)
        path = Dir.glob(File.join(@projects, "*", "#{session_id}.jsonl")).first
        raise Errno::ENOENT, "no transcript for session #{session_id}" unless path && !session_id.to_s.empty?

        states = File.foreach(path).select { |line| line.include?('"worktree-state"') }
        states.empty? ? nil : JSON.parse(states.last).dig("worktreeSession", "worktreePath")
      end

      private

      # The first of these is the brief; any later one is a person.
      def human_messages(path)
        File.foreach(path).map { |line| JSON.parse(line) }.select { |entry| human?(entry) }
      end

      # A user entry is a person's unless something marks it automatic; an entry that cannot be
      # classified counts as a person.
      def human?(entry)
        return false unless entry["type"] == "user"
        return false if automatic_flag?(entry)

        person_origin?(entry["origin"]) && person_content?(entry.dig("message", "content"))
      end

      def automatic_flag?(entry)
        entry["isMeta"] == true || entry["isSidechain"] == true || entry.key?("toolUseResult")
      end

      # An entry with no origin is judged by its content; one with an origin is a person only if
      # it says so.
      def person_origin?(origin)
        origin.nil? || (origin.is_a?(Hash) && origin["kind"] == "human")
      end

      def typed?(text) = !text.match?(AUTOMATIC_TEXT) && !text.start_with?(PIPELINE_MARK)

      def machine_part?(part)
        return false unless part.is_a?(Hash)

        part["type"] == "tool_result" || (part["type"] == "text" && !typed?(part["text"].to_s))
      end

      def person_content?(content)
        case content
        when String then typed?(content)
        when Array then content.none? { |part| machine_part?(part) }
        else true
        end
      end
    end
  end
end
