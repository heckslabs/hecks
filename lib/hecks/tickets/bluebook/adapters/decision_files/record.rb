# frozen_string_literal: true

module Hecks
  module Adapters
    class DecisionFiles < Memory
      # One decision file read for what it says: its number, title, path, the first words of its
      # status line, its date, and the decisions its status line says it supersedes, is superseded
      # by, or narrows. The status line is the first `**Status:**` line in the opening lines, and
      # the status paragraph runs from it to the next blank line.
      class Record
        OPENING     = 12
        PARAGRAPH   = 40
        STATUS      = /\A(?:>\s*)?\*\*Status\b[^:]*:\*\*\s*/
        PLAIN       = /\A(\d{4}[a-z]?)-/
        NESTED      = %r{\A(\d{4})-[^/]+/(\d{2})-}
        FIRST_WORDS = /\A[^.,;:(—–]+/
        FIRST_WORD  = /\A[A-Za-z]+/
        DATE        = /\b\d{4}-\d{2}-\d{2}\b/
        LINK_TARGET = /\]\([^)]*\)/
        ADR         = %r{\b(\d{4}[a-z]?(?:/\d{2})?)\b}
        SENTENCE    = /\.(?=\s|\z)/
        SUPERSEDES    = /\bsupersedes\b/i
        SUPERSEDED_BY = /\bsuperseded(?: in part)? by\b/i
        NARROWS       = /\bnarrows\b/i

        # @return [String, nil] the record's number, nil when the file name carries none
        attr_reader :number
        # @return [String] the file, relative to the first of `bases` that holds it
        attr_reader :path

        # @param file [String] the file's absolute path
        # @param directory [String] the decision directory the file is under
        # @param bases [Array<String, nil>] the directories a path is given relative to, in order
        # @param words [Hash{String => String}] first word, without case, to lifecycle status
        def initialize(file, directory:, bases:, words:)
          within   = file.delete_prefix("#{directory}/")
          @number  = number_of(within)
          @path    = relative(file, bases.compact.map { |base| File.expand_path(base) }, directory)
          @words   = words
          @lines   = File.foreach(file).first(PARAGRAPH)
          @status  = status_paragraph
        end

        # Whether the store can hold the record: it has a number, a status line and a first word a
        # `StatusWord` row names.
        #
        # @return [Boolean]
        def readable? = !(@number.nil? || @status.nil? || lifecycle.nil?)

        # Why the store leaves the record out.
        #
        # @return [String] the path and the reason
        def why
          return "#{@path}: no NNNN- number in its name" if @number.nil?
          return "#{@path}: no status line in its first #{OPENING} lines" if @status.nil?

          "#{@path}: status word #{first_word.inspect} names no StatusWord row"
        end

        # The record's state, in the shape the store holds.
        #
        # @return [Hash{Symbol => Object}]
        def state
          { adr: { value: @number }, title: { value: title }, path: { value: @path }, status: lifecycle,
            wording: { value: cleaned[FIRST_WORDS].to_s.strip }, **date, **relations }
        end

        private

        def number_of(within)
          nested = within.match(NESTED) and return "#{nested[1]}/#{nested[2]}"
          within[PLAIN, 1]
        end

        def relative(file, bases, directory)
          base = bases.find { |candidate| file.start_with?("#{candidate}/") } || directory
          file.delete_prefix("#{base}/")
        end

        def status_paragraph
          start = @lines.first(OPENING).index { |line| line.match?(STATUS) } or return nil
          paragraph = @lines.drop(start).take_while { |line| !line.strip.empty? }
          paragraph.join(" ").sub(STATUS, "")
        end

        def title
          heading = @lines.find { |line| line.start_with?("# ") }
          heading ? heading.delete_prefix("# ").strip : File.basename(@path, ".md")
        end

        def first_word = @status.to_s[FIRST_WORD].to_s

        def lifecycle = @words[first_word.downcase]

        def date
          found = @status[DATE]
          found ? { date: { value: found } } : {}
        end

        # The status paragraph with link targets and dates removed, so a number in a file name or a
        # year never reads as a decision.
        def cleaned
          @cleaned ||= begin
            without_links = @status.gsub(LINK_TARGET, "")
            without_links.gsub(DATE, "")
          end
        end

        def relations
          { supersedes: numbers_after(SUPERSEDES), superseded_by: numbers_after(SUPERSEDED_BY),
            narrows: numbers_after(NARROWS), narrowed_by: [] }
        end

        # The decision numbers in the clause after each `keyword`, up to the end of its sentence.
        def numbers_after(keyword)
          clauses = cleaned.to_enum(:scan, keyword).map { clause_after(Regexp.last_match) }
          clauses.flat_map { |clause| clause.scan(ADR).flatten }.uniq.map { |found| { value: found } }
        end

        # The rest of the sentence after a keyword match.
        def clause_after(match)
          sentence, = match.post_match.split(SENTENCE, 2)
          sentence.to_s
        end
      end
    end
  end
end
