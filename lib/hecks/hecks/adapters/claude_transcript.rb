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

      # @param projects [String] the directory holding the per-project transcript folders
      def initialize(projects: File.join(Dir.home, PROJECTS))
        @projects = projects
      end

      # @param session_id [String] the full session id, which names the transcript file
      # @return [Boolean] true when a person replied after the brief, or when this cannot be told
      def taken_over?(session_id)
        path = Dir.glob(File.join(@projects, "*", "#{session_id}.jsonl")).first
        return true unless path && !session_id.to_s.empty?

        human_messages(path).length > 1
      rescue SystemCallError, JSON::ParserError
        true
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

      def person_content?(content)
        case content
        when String then !content.match?(AUTOMATIC_TEXT)
        when Array then content.none? { |part| part.is_a?(Hash) && part["type"] == "tool_result" }
        else true
        end
      end
    end
  end
end
