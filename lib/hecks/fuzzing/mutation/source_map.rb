module Hecks
  module Fuzzing
    module Mutation
      # What a bluebook's source says about itself, so a finder can ask where a line sits: the block
      # keyword it is inside, how long the block that starts on it runs, and which lifecycle states
      # and events the file names.
      class SourceMap
        # A line that opens a block, as `policy "X" do` or `command "Y", from: "z" do |a|`.
        OPENER = /\A(\s*)(\w+)\b.*\bdo\s*(\|[^|]*\|)?\s*\z/
        TRANSITION = /\A(\s*)transition\s+"(\w+)"\s*=>\s*"([^"]+)"(.*?)\s*\z/
        EMITS = /\A(\s*)emits\s+(\w+)\s*\z/

        attr_reader :file, :lines

        # @param file [String] the bluebook's path relative to the domain directory
        # @param lines [Array<String>] its lines, newline-terminated
        def initialize(file, lines)
          @file = file
          @lines = lines
          @scopes = compute_scopes
        end

        # @param index [Integer] a line's position, from 0
        # @return [String, nil] the keyword of the innermost block the line is inside
        def scope(index) = @scopes[index]

        # @return [Array<String>] every state a `transition` in the file moves to
        def states
          @states ||= lines.filter_map { |line| line[TRANSITION, 3] }.uniq
        end

        # @return [Array<String>] every event name a command in the file emits
        def emitted
          @emitted ||= lines.filter_map { |line| line[EMITS, 2] }.uniq
        end

        # @param index [Integer] the position of the line that opens a block
        # @return [Integer, nil] the lines from it to its `end`, nil when the block never closes
        def block_length(index)
          indent = lines[index][/\A\s*/]
          close = ((index + 1)...lines.length).find { |at| lines[at].match?(/\A#{indent}end\b/) }
          close && ((close - index) + 1)
        end

        private

        def compute_scopes
          stack = []
          lines.map do |line|
            stack.pop while stack.any? && line.match?(/\A#{stack.last[0]}end\b/)
            inside = stack.last&.last
            (match = line.match(OPENER)) && stack.push([match[1], match[2]])
            inside
          end
        end
      end
    end
  end
end
