module Hecks
  module Doc
    module Reference
      # Reads the hand-written prose back out of a committed reference page: everything between a
      # section's generated region and the next `## ` heading, keyed by word.
      #
      # Starts collecting under `PREAMBLE` (not nil) so a page written before that region existed
      # still parses unchanged. A `## ` line inside a fence is not a heading: it is a comment in
      # the runnable example, not a section break.
      class Harvester
        def initialize
          @prose = {}
          @current = PREAMBLE
          @collecting = false
          @buffer = []
          @in_fence = false
        end

        # @param text [String] a reference page
        # @return [Hash{String, Symbol => String}] each word's prose (the preamble under
        #   `PREAMBLE`), leaving out a word with none or only the TODO sentinel
        def call(text)
          text.each_line { |line| consume(line) }
          flush
          @prose.reject { |_word, body| body.empty? || body == TODO_SENTINEL }
        end

        private

        def consume(line)
          @in_fence = !@in_fence if line.start_with?("```")
          heading = line.match(/\A## (\S+)\s*\z/) unless @in_fence
          if heading
            start_section(heading[1])
          elsif line.include?(GENERATED_END)
            @collecting = true
          elsif @collecting
            @buffer << line
          end
        end

        def start_section(word)
          flush
          @current = word
          @collecting = false
          @buffer = []
        end

        def flush
          @prose[@current] = @buffer.join.strip if @current && @collecting
        end
      end
    end
  end
end
