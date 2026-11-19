# frozen_string_literal: true

module Hecks
  module Landing
    # A bluebook's text cut into its top-level declarations, so that two edits of one file can be
    # told apart by the declarations they touch.
    #
    # The declaration depth is the indent of the first `aggregate` or `policy` line. Each line that
    # starts a call at that depth opens a part, which runs through its deeper lines and the `end` at
    # its depth; the comments and blank lines before it are part of it. The text before the first
    # part is the head, and from the first shallower line after the parts, the tail. Joining the
    # head, the parts and the tail gives back the text byte for byte. This is a reading of the text,
    # like a projection, and decides nothing.
    class Declarations
      # A line that marks the declaration depth.
      ANCHOR = /\A(?<indent>[ \t]*)(?:aggregate|policy)\b/

      # A call's word and the name it declares, when it gives one.
      CALL = /\A[ \t]*(?<kind>[a-z_]+)\b[ (]*(?:"(?<name>[^"]*)"|:(?<name>\w+))?/

      # One declaration: its key (`aggregate Coder`), its name (`Coder`) and its lines.
      Part = Struct.new(:key, :name, :text)

      # @return [String] the text before the first declaration
      attr_reader :head
      # @return [Array<Part>] the declarations, in order
      attr_reader :parts
      # @return [String] the text after the last declaration
      attr_reader :tail

      # @param text [String] a bluebook's source
      def initialize(text)
        lines = text.to_s.lines
        depth = lines.map { |line| line[ANCHOR, :indent] }.compact.first
        @head = ""
        @parts = []
        @tail = ""
        depth ? cut(lines, depth) : @head = text.to_s
      end

      # @return [String] the text the parts were cut from
      def to_s = [head, *parts.map(&:text), tail].join

      # @return [Hash{String => Part}] the parts by key
      def by_key = parts.to_h { |part| [part.key, part] }

      private

      def cut(lines, depth)
        start = lines.index { |line| line.start_with?(depth) && line[ANCHOR] }
        start = back_over_comments(lines, start, depth)
        @head = lines[0...start].join
        finish = Cutting.new(lines, depth, start).call { |text| add(text) }
        @tail = lines[finish..].to_a.join
      end

      def back_over_comments(lines, start, depth)
        start -= 1 while start.positive? && lead?(lines[start - 1], depth)
        start
      end

      def lead?(line, depth) = line.strip.empty? || (line.start_with?(depth) && line.strip.start_with?("#"))

      def add(text)
        call = opening(text).match(CALL)
        name = call && call[:name]
        @parts << Part.new(unique([call && call[:kind], name].compact.join(" ")), name, text)
      end

      # @return [String] the part's first line that is not a comment or blank
      def opening(text) = text.lines.find { |line| !lead?(line, "") }.to_s

      def unique(key)
        return key unless by_key.key?(key)

        "#{key} ##{parts.count { |part| part.key.start_with?(key) } + 1}"
      end

      # The walk over the lines that splits them into parts at one depth.
      class Cutting
        # A character that indents a line deeper.
        SPACE = /\s/

        # @param lines [Array<String>] the text's lines
        # @param depth [String] the declaration indent
        # @param start [Integer] the first line of the first part
        def initialize(lines, depth, start)
          @lines = lines
          @depth = depth
          @at = start
        end

        # @yieldparam text [String] each part's text, in order
        # @return [Integer] the index of the first line of the tail
        def call
          while @at < @lines.size
            first = @at
            skip_leads
            next yield take_body(first) if declaration?(@lines[@at])

            return first
          end
          @at
        end

        private

        def skip_leads
          @at += 1 while @at < @lines.size && lead?(@lines[@at])
        end

        def lead?(line) = line.strip.empty? || (deeper_or_at?(line) && line.strip.start_with?("#"))

        def declaration?(line) = line&.start_with?(@depth) && !line[@depth.size].match?(SPACE)

        def deeper_or_at?(line) = line.start_with?(@depth)

        def take_body(first)
          @at += 1
          @at += 1 while @at < @lines.size && inside?(@lines[@at])
          @at += 1 if @at < @lines.size && @lines[@at].rstrip == "#{@depth}end"
          @lines[first...@at].join
        end

        def inside?(line) = line.strip.empty? || (line.start_with?(@depth) && line[@depth.size].match?(SPACE))
      end
    end
  end
end
