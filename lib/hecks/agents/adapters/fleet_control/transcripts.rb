# frozen_string_literal: true

require "json"

module Hecks
  module Adapters
    class FleetControl
      # The sessions' transcripts under the projects directory, one `<session>.jsonl` each: what a
      # person and the model wrote in them, and the directory the session worked in.
      class Transcripts
        # The widest piece of a matching line a read shows.
        SHOWN = 160

        # @param projects [String] the directory holding the per-project transcript folders
        def initialize(projects)
          @projects = projects
        end

        # @param session [String] the full session id
        # @param topic [String] the words looked for, in any case
        # @return [String, nil] the first line of the transcript's text that mentions the topic
        def mention(session, topic)
          wanted = topic.to_s.downcase
          texts(session).each do |text|
            line = text.lines.find { |candidate| candidate.downcase.include?(wanted) }
            return line.strip[0, SHOWN] if line
          end
          nil
        end

        # @param session [String] the full session id
        # @return [String, nil] the directory the session worked in, as its transcript records it
        def directory(session) = entries(session).lazy.filter_map { |entry| entry["cwd"] }.first

        # @param session [String] the full session id
        # @return [Time] when the transcript was last written; the epoch when there is none
        def written_at(session)
          path = path_of(session)
          path ? File.mtime(path) : Time.at(0)
        end

        private

        def texts(session) = entries(session).filter_map { |entry| text_of(entry.dig("message", "content")) }

        def text_of(content)
          return content if content.is_a?(String)
          return unless content.is_a?(Array)

          content.filter_map { |part| part["text"] if part.is_a?(Hash) }.join("\n")
        end

        def entries(session)
          path = path_of(session)
          return [] unless path

          File.foreach(path).filter_map { |line| parse(line) }
        rescue SystemCallError
          []
        end

        def parse(line)
          entry = JSON.parse(line)
          entry if entry.is_a?(Hash)
        rescue JSON::ParserError
          nil
        end

        def path_of(session)
          return if session.to_s.empty?

          Dir.glob(File.join(@projects, "*", "#{session}.jsonl")).first
        end
      end
    end
  end
end
