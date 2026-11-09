# frozen_string_literal: true

require "hecks/adapters/driven/memory"
require "hecks/refused"
require_relative "decision_files/directory"
require_relative "decision_files/record"
require_relative "decision_files/reading"
require_relative "decision_files/relations"

module Hecks
  module Adapters
    # The Persistence adapter behind `Tickets::Adr`: a Memory store filled at boot from the decision
    # files under `docs/decisions`, which takes no write while the files back it.
    #
    # The `directory` setting names the files, relative to the checkout that holds the booted
    # domain (the nearest directory above the registry's root holding `hecks.gemspec`) or
    # absolute. `None`, or no setting, leaves the store a plain Memory one that takes writes as
    # Memory does: what a standalone, fuzz or model_check boot and a spec get. Each file is read for
    # what it says ({Record}); which lifecycle status its first status word means is the bluebook's
    # `StatusWord` rows, read here and decided nowhere else; `superseded_by` and `narrowed_by` are
    # derived from the other records' `supersedes` and `narrows` ({Relations}). A file the store
    # cannot hold (no status line, a first word no row names, a number two files share) is left
    # out and named on standard error, so a boot never refuses over a decision file.
    class DecisionFiles < Memory
      STATUS_WORDS = "StatusWord"

      # @return [String, nil] the decision directory; nil when the store is plain Memory
      attr_reader :directory
      # @return [Array<String>] one line per file left out, naming the file and why
      attr_reader :left_out

      # @param aggregate [Bluebook::Aggregate] `Tickets::Adr`
      # @param settings [Hash] `directory:` as the world names it
      # @param root [String, nil] the registry's root, from which the checkout is found
      def initialize(aggregate:, settings: {}, root: nil)
        super
        @directory = Directory.resolve(settings[:directory], root)
        @left_out  = []
        load_records!(root) if @directory
      end

      # Journals one entry. Refused by name while the files back the store: a decision's status is
      # its file's status line until writing it back is built.
      #
      # @param entry [Ports::Persistence::Entry] the save or delete
      # @return [Ports::Persistence::Entry] the entry, in a plain Memory store
      # @raise [Hecks::Refused] in a store read from files
      def append(entry)
        return super unless @directory

        raise Hecks::Refused, "decisions are read from #{@directory}: edit the status line of the record's file"
      end

      private

      def load_records!(root)
        reading   = Reading.new(@directory, bases: [Directory.checkout(root), root], words: status_words)
        @left_out = reading.left_out
        Relations.derive(reading.states).each { |state| project(entry_for(state)) }
        warn_left_out
      end

      def entry_for(state)
        Ports::Persistence::Entry.new(operation: "save", id: state[:adr][:value], state: state)
      end

      # The `StatusWord` rows: first word, without case, to lifecycle status.
      def status_words
        rows = @aggregate.value_objects.find { |shape| shape.hecks_name == STATUS_WORDS }
        Array(rows&.members).to_h { |row| [row[:word].to_s.downcase, row[:status].to_s] }
      end

      def warn_left_out
        return if @left_out.empty?

        warn "[hecks] Tickets::Adr: decision files under #{@directory} not loaded:"
        @left_out.each { |line| warn "[hecks]   #{line}" }
      end
    end
  end
end
