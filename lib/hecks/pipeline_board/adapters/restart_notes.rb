# frozen_string_literal: true

require "json"
require "time"
require "tmpdir"

module Hecks
  module Adapters
    module PipelineBoard
      # The times the board's sentinel restarted a board that had stopped answering, kept for the
      # board's header. It is a reading for display, not the record of an aggregate: a small file
      # in the temporary directory that the sentinel process appends to and a starting board reads,
      # so the note outlives the restart it describes.
      class RestartNotes
        # The notes kept; older ones are dropped when a new one is added.
        KEPT = 20
        # Where the notes are kept between boards.
        PATH = File.join(Dir.tmpdir, "hecks-pipeline-board-restarts.json")

        class << self
          # Adds a note for a restart that happened now.
          # @param misses [Integer] the unanswered asks in a row that led to it
          # @param path [String] the file the notes are kept in
          # @param now [Time] the time of the restart
          # @return [Array<Hash>] the notes kept
          def record(misses:, path: PATH, now: Time.now.utc)
            kept = (read(path) + [{ "at" => now.iso8601, "misses" => misses }]).last(KEPT)
            File.write(path, JSON.generate(kept))
            kept
          rescue SystemCallError
            []
          end

          # @param path [String] the file the notes are kept in
          # @return [Hash{Symbol => Array<String>}, nil] `notes` as sentences, newest last; nil when
          #   the board has never restarted itself
          def reading(path: PATH)
            notes = read(path)
            return nil if notes.empty?

            { notes: notes.last(3).map { |note| sentence(note) } }
          end

          # @return [Hash] what the board's state carries about its own restarts
          def with_state = { board_restarts: reading }

          private

          def read(path)
            JSON.parse(File.read(path))
          rescue SystemCallError, JSON::ParserError
            []
          end

          def sentence(note)
            "restarted itself at #{Time.parse(note["at"]).localtime.strftime("%H:%M")} " \
              "after #{note["misses"]} missed answers"
          end
        end
      end
    end
  end
end
