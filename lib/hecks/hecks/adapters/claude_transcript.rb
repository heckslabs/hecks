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
      # The directory, under the home directory, the transcripts are kept in, one folder per project.
      PROJECTS = File.join(".claude", "projects")

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

      def human?(entry)
        return false unless entry["type"] == "user"

        content = entry.dig("message", "content")
        content.is_a?(String) || (content.is_a?(Array) && content.none? { |part| part["type"] == "tool_result" })
      end
    end
  end
end
