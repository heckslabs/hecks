module Hecks
  module Projector
    # What a launcher's help leaves out and points at for whoever typed the line: the aggregates
    # only a maintainer of a hecks checkout runs, and the attached bluebooks worth a line each.
    # `CliProjector` renders the help; the runner decides the audience
    # (`Adapters::Driving::LauncherOptions`).
    module CliAudience
      # The partial word at the end of a cut line, with the space before it.
      TRAILING_PARTIAL_WORD = /\s+\S*\z/

      module_function

      # The specs whose aggregate the audience does not run.
      def without_hidden(specs, hide)
        hidden = Array(hide)
        hidden.empty? ? specs : specs.reject { |_, spec| hidden.include?(spec[:group]) }
      end

      # The specs the options' audience is shown: those not hidden, and only those listed, if any
      # are.
      def audience_specs(specs, options)
        only_listed(without_hidden(specs, options[:hide]), options[:only])
      end

      # The specs a newcomer is shown: only those named, or all of them when none are.
      def only_listed(specs, only)
        listed = Array(only)
        listed.empty? ? specs : specs.slice(*listed)
      end

      # The line saying the help lists only the first steps and how to list the rest, or no line
      # when it lists everything.
      def newcomer_hint(program, only)
        return [] if Array(only).empty?

        ["  #{program} --all                  also list every command (no bluebook is in this folder yet)"]
      end

      # The attached bluebooks the help points at, one line each, under the call that opens them.
      #
      # @param bluebooks [Array<Array(String, String)>, nil] each bluebook's word and its summary
      def bluebook_lines(program, declarations)
        return [] if Array(declarations).empty?

        width = declarations.map { |word, _| word.length }.max
        ["", "bluebooks (`#{program} <bluebook>` lists a bluebook's own commands and queries):",
         *declarations.map { |word, summary| "  #{word.ljust(width)}  #{clipped(summary)}".rstrip }]
      end

      # A summary cut to one terminal line, at a word, with an ellipsis where it was cut.
      def clipped(text, limit = 96)
        return text if text.length <= limit

        "#{text[0, limit].sub(TRAILING_PARTIAL_WORD, "")}…"
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
