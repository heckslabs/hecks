# frozen_string_literal: true

require "json"

module Hecks
  module Adapters
    # The whole of what a background session wrote last, read from its transcript: the job keeps
    # only the tail of that message, so a long one loses its opening there.
    #
    # The closing message is the text of the last assistant entry of the session's own thread
    # that carries text; an entry that only uses a tool, and a subagent's entry, are passed over.
    # It judges nothing, and answers empty when the transcript cannot be found or read.
    class ClaudeClosingMessage
      # The directory, under the home directory, the transcripts are kept in, one per project.
      PROJECTS = File.join(".claude", "projects")

      # The characters a glob pattern reads as wildcards, escaped so an id matches only itself.
      GLOB = /[*?\[\]{}\\]/

      # @param projects [String] the directory holding the per-project transcript folders
      def initialize(projects: File.join(Dir.home, PROJECTS))
        @projects = projects
      end

      # @param session [String] the session's id, or the short id a job and a run hold, which
      #   begins the transcript file's name
      # @return [String] the closing message whole, or empty when no one transcript matches the id,
      #   it holds no text, or it cannot be read
      def of(session)
        path = transcript(session.to_s)
        path ? remembered(path) : ""
      rescue SystemCallError, JSON::ParserError
        ""
      end

      # What every reader of a transcript shares: where each session's file was found, and the text
      # last read from a file with the size and time it had then.
      MEMORY = { paths: {}, texts: {}, lock: Mutex.new }.freeze

      private

      # A transcript's closing text, read again only when the file's size or time has moved, so a
      # finished session is parsed once however many pages ask.
      def remembered(path)
        stat = File.stat(path)
        stamp = [stat.size, stat.mtime]
        held = MEMORY[:lock].synchronize { MEMORY[:texts][path] }
        return held.last if held && held.first == stamp

        last_text(path).tap { |text| MEMORY[:lock].synchronize { MEMORY[:texts][path] = [stamp, text] } }
      end

      # The one transcript whose name begins with the id; none when the id is empty or matches
      # more than one.
      def transcript(session)
        return nil if session.empty?

        key = [@projects, session]
        known = MEMORY[:lock].synchronize { MEMORY[:paths][key] }
        return known if known && File.file?(known)

        glob(session)&.tap { |found| MEMORY[:lock].synchronize { MEMORY[:paths][key] = found } }
      end

      def glob(session)
        paths = Dir.glob(File.join(@projects, "*", "#{session.gsub(GLOB) { "\\#{_1}" }}*.jsonl"))
        paths.length == 1 ? paths.first : nil
      end

      # Only lines that name an assistant entry are parsed, so a long transcript is not read whole.
      def last_text(path)
        texts = File.foreach(path).select { |line| line.include?('"assistant"') }.map { |line| text_of(JSON.parse(line)) }
        texts.reject(&:empty?).last.to_s
      end

      # The joined text blocks of the session's own assistant entry, or empty for any other entry.
      def text_of(entry)
        return "" unless entry["type"] == "assistant" && entry["isSidechain"] != true

        parts = Array(entry.dig("message", "content")).select { |part| part.is_a?(Hash) && part["type"] == "text" }
        parts.map { |part| part["text"].to_s }.join
      end
    end
  end
end
