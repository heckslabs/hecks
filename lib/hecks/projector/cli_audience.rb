module Hecks
  module Projector
    # What a launcher's help leaves out and points at for whoever typed the line: the aggregates
    # only a maintainer of a hecks checkout runs, and the attached chapters worth a line each.
    # `CliProjector` renders the help; the runner decides the audience (`Doors::LauncherOptions`).
    module CliAudience
      module_function

      # The specs whose aggregate the audience does not run.
      def without_hidden(specs, hide)
        hidden = Array(hide)
        hidden.empty? ? specs : specs.reject { |_, spec| hidden.include?(spec[:group]) }
      end

      # The attached chapters the help points at, one line each, under the call that opens them.
      #
      # @param chapters [Array<Array(String, String)>, nil] each chapter's word and its summary
      def chapter_lines(program, chapters)
        return [] if Array(chapters).empty?

        width = chapters.map { |word, _| word.length }.max
        ["", "chapters (`#{program} <chapter>` lists a chapter's own commands and queries):",
         *chapters.map { |word, summary| "  #{word.ljust(width)}  #{clipped(summary)}".rstrip }]
      end

      # A summary cut to one terminal line, at a word, with an ellipsis where it was cut.
      def clipped(text, limit = 96)
        return text if text.length <= limit

        "#{text[0, limit].sub(/\s+\S*\z/, '')}…"
      end

      # The line saying the commands for working on hecks itself were left out and how to list
      # them, or no line when none were.
      def maintainer_hint(program, count)
        return [] unless count.positive?

        ["  #{program} --maintainer           also list the #{count} commands and queries for working on hecks itself"]
      end
    end
  end
end
