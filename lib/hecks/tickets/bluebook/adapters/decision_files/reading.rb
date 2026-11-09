# frozen_string_literal: true

module Hecks
  module Adapters
    class DecisionFiles < Memory
      # What a decision directory's files say: the states of the records the store holds, and one
      # line for each file it leaves out, because the file has no number, no status line, a first
      # word no `StatusWord` row names, or a number another file shares (a number two records carry
      # resolves no Work decision, so neither is held).
      class Reading
        PLAIN  = "[0-9][0-9][0-9][0-9]*-*.md"
        NESTED = File.join("[0-9][0-9][0-9][0-9]-*", "[0-9][0-9]-*.md")

        # @return [Array<Hash>] the held records' states, in file order
        attr_reader :states
        # @return [Array<String>] a line per file left out, naming it and why; one line per number
        #   two or more files share, naming them all
        attr_reader :left_out

        # @param directory [String] the decision directory
        # @param bases [Array<String, nil>] the directories a record's path is given relative to
        # @param words [Hash{String => String}] first word, without case, to lifecycle status
        def initialize(directory, bases:, words:)
          records = files(directory).map { |file| Record.new(file, directory: directory, bases: bases, words: words) }
          @shared = shared_numbers(records)
          held, out = records.partition { |record| holds?(record) }
          @states   = held.map(&:state)
          @left_out = shared_lines + out.reject { |record| @shared.key?(record.number) }.map(&:why)
        end

        private

        def files(directory)
          Dir.glob([File.join(directory, PLAIN), File.join(directory, NESTED)])
        end

        # The numbers two or more files carry, each with those files' paths.
        def shared_numbers(records)
          records.group_by(&:number).select { |number, same| number && same.size > 1 }
                 .transform_values { |same| same.map(&:path) }
        end

        def holds?(record) = record.readable? && !@shared.key?(record.number)

        def shared_lines
          @shared.map { |number, paths| "number #{number} is #{paths.join(" and ")}'s; renumber all but one" }
        end
      end
    end
  end
end
