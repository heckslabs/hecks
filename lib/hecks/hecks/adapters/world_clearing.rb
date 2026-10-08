# frozen_string_literal: true

module Hecks
  module Adapters
    # Empties the `deployed_to(...) do ... end` blocks of a `.world` file's text: the region,
    # stacks, secrets, domain and buckets a host deploys with, which a project handed to a client
    # must not carry. Each block keeps its opening and closing lines and holds one comment naming
    # the settings it held, so the file still loads and shows what to set.
    #
    # A block closes at the first `end` at its own indent, and a setting is a line one indent
    # step inside it that starts with its name. A block that holds only comments is already clear
    # and is left as it is, so clearing twice changes nothing the second time.
    class WorldClearing
      BLOCK = /^(?<indent>[ \t]*)deployed_to\b[^\n]*[ \t]do\b[^\n]*\n(?<body>.*?)^\k<indent>end\b[^\n]*\n/m

      # What clearing one world's text produced.
      #
      # @!attribute [r] text
      #   @return [String] the text with every block emptied
      # @!attribute [r] settings
      #   @return [Array<String>] the setting names removed, in order, without repeats
      Result = Struct.new(:text, :settings) do
        # @return [Boolean] whether any block was emptied
        def changed? = !settings.empty?
      end

      # @param text [String] the contents of a `.world` file
      # @return [Result] the cleared text and the settings that were in the blocks
      def self.call(text)
        names = []
        cleared = text.gsub(BLOCK) { |block| empty(Regexp.last_match, block, names) }
        Result.new(cleared, names.uniq)
      end

      # @param match [MatchData] one `deployed_to` block
      # @param block [String] the block's text
      # @param names [Array<String>] collects the setting names removed
      # @return [String] the block's replacement
      def self.empty(match, block, names)
        indent = match[:indent]
        held = match[:body].scan(/^#{indent} {2}([a-z_]\w*)/).flatten
        return block if held.empty?

        names.concat(held)
        "#{block.lines.first}#{comment(indent, note(held.uniq))}#{indent}end\n"
      end

      # @param held [Array<String>] the setting names the block held
      # @return [String] the comment that stands where the settings were
      def self.note(held)
        "The host's deployment settings were removed from this handoff. Set your own: #{held.join(", ")}."
      end

      # @param indent [String] the block's indent
      # @param note [String] the sentence to put in the block
      # @return [String] the sentence as comment lines inside the block, folded under 100 columns
      def self.comment(indent, note)
        width = 96 - indent.size
        note.scan(/(.{1,#{width}})(?:\s+|\z)/).flatten.map { |line| "#{indent}  # #{line}\n" }.join
      end

      private_class_method :empty, :note, :comment
    end
  end
end
