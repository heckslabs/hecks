# frozen_string_literal: true

require "fileutils"
require "json"

module Hecks
  module Adapters
    # The `Journaling` port's adapter for `Edit`: answers the `Append` ask by appending one JSON
    # line to the journal file, so a recorded edit outlives the process.
    #
    # The journal only grows. A withdrawal is appended as a record of its own, and no line is ever
    # edited. It decides nothing about an edit: the bluebook's guards say what may be gathered.
    class EditJournal
      # Where the journal lives, when the settings name no other path.
      DEFAULT_PATH = "~/.claude/hecks-dev/local_layer.journal"

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `path:` the journal file (default {DEFAULT_PATH})
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @path = File.expand_path(settings[:path] || DEFAULT_PATH)
      end

      # Appends the edit as it stands.
      #
      # @param held [Hash] the `Edit` record: `run`, `status` and the edit's fields
      # @return [Hash{Symbol => Object}] `journaled:` the number of lines the journal now holds
      # @raise [SystemCallError] when the journal cannot be written
      def append(**held)
        FileUtils.mkdir_p(File.dirname(@path))
        File.open(@path, "a") { |file| file.puts(JSON.generate(held)) }
        { journaled: { value: File.foreach(@path).count } }
      end
    end
  end
end
