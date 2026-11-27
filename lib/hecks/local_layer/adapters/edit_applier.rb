# frozen_string_literal: true

module Hecks
  module Adapters
    # Turns a bluebook's text and a batch's typed edits into the text with the edits applied. It is
    # pure: it reads nothing, writes nothing and checks nothing about the result; the validators do.
    #
    # An edit's `subject` is `Aggregate` or `Aggregate.field`, and its `detail` says the change:
    #
    # - `AddTransition`, `AddMark`, `AddPolicy`, `AddCommand`, `AddAttribute`: `detail` is the
    #   declaration line, inserted just below the line that opens the subject: `lifecycle :field`
    #   when the subject names a field, else the aggregate line.
    # - `RemoveTransition`: `detail` is text; every line of the aggregate holding it is removed.
    # - `RenameState`: `detail` is `old=>new`; the quoted state is renamed within the aggregate.
    class EditApplier
      # Raised when an edit cannot be applied to the text.
      class Unapplicable < StandardError; end

      # The leading whitespace of a line.
      INDENT = /\A\s*/

      # @param text [String] the bluebook source
      # @param edits [Array<Hash>] each with `:operation`, `:subject` and `:detail`, as plain strings
      # @return [String] the source with every edit applied in order
      # @raise [Unapplicable] when an edit names an aggregate or a line the text does not hold
      def self.call(text, edits)
        edits.reduce(text.lines) { |lines, edit| new(lines, edit).apply }.join
      end

      # @param lines [Array<String>] the source's lines
      # @param edit [Hash] one edit
      def initialize(lines, edit)
        @lines = lines.dup
        @edit = edit
        @aggregate, @field = edit[:subject].split(".", 2)
      end

      # @return [Array<String>] the lines with this edit applied
      def apply
        case @edit[:operation]
        when "RemoveTransition" then remove
        when "RenameState"      then rename
        else insert
        end
      end

      private

      def start
        @lines.index { |line| line.match?(/\A\s*aggregate\s+"#{Regexp.escape(@aggregate)}"/) } or
          raise Unapplicable, "no aggregate #{@aggregate} in the target"
      end

      def span
        first = start
        indent = @lines[first][INDENT]
        last = ((first + 1)...@lines.size).find { |i| @lines[i].match?(/\A#{indent}end\b/) }
        last ? first..last : raise(Unapplicable, "aggregate #{@aggregate} is not closed")
      end

      def anchor
        range = span
        return range.first unless @field

        range.find { |i| @lines[i].match?(/\blifecycle\s+:#{Regexp.escape(@field)}\b/) } or
          raise Unapplicable, "no lifecycle #{@field} in #{@aggregate}"
      end

      def insert
        at = anchor
        @lines.insert(at + 1, "#{@lines[at][INDENT]}  #{@edit[:detail]}\n")
      end

      def remove
        hit = span.select { |i| @lines[i].include?(@edit[:detail]) }
        raise Unapplicable, "no line of #{@aggregate} holds #{@edit[:detail]}" if hit.empty?

        @lines.reject.with_index { |_, i| hit.include?(i) }
      end

      def rename
        old, new = @edit[:detail].split("=>", 2).map(&:strip)
        span.each { |i| @lines[i] = @lines[i].gsub("\"#{old}\"", "\"#{new}\"") }
        @lines
      end
    end
  end
end
