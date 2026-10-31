module Hecks
  module Projector
    module CliProjector
      # The lines the help opens with: the commands and queries a person types most, which the
      # launcher setting names as `everyday`, each line the call to type (ADR 0163).
      module Everyday
        # The `everyday` section: a heading, then one row per named command or query the audience
        # is shown, in the setting's order, each spelled in full. A name the audience is not shown,
        # or that names nothing, is left out; nothing is listed for a newcomer, whose help lists
        # only the newcomer commands.
        #
        # @param commands [Hash{String => Hash}] the command specs the audience is shown
        # @param questions [Hash{String => Hash}] the query specs the audience is shown
        # @param options [Hash] the projection's options; `:everyday` names the lines, `:only`
        #   marks a newcomer's help
        # @return [Array<String>] the section's lines, or none
        def everyday_lines(commands, questions, options)
          return [] if Array(options[:only]).any?

          specs = Array(options[:everyday]).filter_map { |name| commands[name] || questions[name] }
          return [] if specs.empty?

          ["everyday:", *everyday_rows(specs), ""]
        end

        # How much of what a line does fits beside its call on one terminal line.
        EVERYDAY_TEXT = 72

        # One row per spec: its full call padded to the widest, then the first sentence of what it
        # does, cut at a word to fit one line.
        def everyday_rows(specs)
          row = row_formatter(specs.to_h { |spec| [spec, label(spec, real: true)] }) do |spec|
            CliAudience.clipped(first_sentence(spec[:summary]), EVERYDAY_TEXT)
          end
          specs.map { |spec| row.call(spec, "  ") }
        end
      end
    end
  end
end
