module Hecks
  module Projector
    module CliProjector
      # The `--help` text of one command or query.
      module CommandHelp
        # Four independent blocks, concatenated in fixed order: meta, invocation,
        # arguments, refusals.
        def command_help(program, name, spec, ask: false)
          out = command_help_meta_lines(name, spec)
          out.concat(command_help_invocation_lines(program, name, spec, ask))
          out.concat(command_help_argument_lines(spec))
          out.concat(command_help_refusal_lines(spec))
          out.join("\n")
        end

        # The title, what the command dispatches or reads, and who issues it.
        def command_help_meta_lines(name, spec)
          out = ["#{name} — #{spec[:summary]}", ""]
          out << "dispatches #{spec[:command]}" if spec[:kind] == :command
          out << "reads #{spec[:command]}"      if spec[:kind] == :query
          out << "issued by #{spec[:role]}" if spec[:role]
          out
        end

        # The example call with every argument as `path=…`.
        def command_help_invocation_lines(program, name, spec, ask)
          invocation = ask ? "#{program} query #{name}" : "#{program} #{name}!"
          ["", "  #{invocation}#{spec[:arguments].map { |a| " #{a[:path]}=…" }.join}", ""]
        end

        # One line per argument: its path padded to the widest, then its notes.
        def command_help_argument_lines(spec)
          return [] if spec[:arguments].empty?

          width = spec[:arguments].map { |a| a[:path].length }.max
          lines = spec[:arguments].map do |argument|
            "  #{argument[:path].ljust(width)}  #{argument_notes(argument).join("; ")}"
          end
          lines << ""
        end

        # What an argument's line says about it: type, constraints, note, then `optional`.
        def argument_notes(argument)
          [argument[:type], *constraint_notes(argument), *argument[:note], *("optional" unless argument[:required])]
        end

        # The enum, pattern and default an argument carries.
        def constraint_notes(argument)
          notes = []
          notes << "one of #{argument[:enum].join(", ")}" if argument[:enum]
          notes << "matches #{argument[:pattern]}"        if argument[:pattern]
          notes << "defaults to #{argument[:default].inspect}" unless argument[:default].nil?
          notes
        end

        # The `refused when:` and `refused unless:` blocks, each present only when it has items.
        def command_help_refusal_lines(spec)
          [["refused when:", spec[:refusals]], ["refused unless:", spec[:requirements]]].flat_map do |heading, items|
            Array(items).empty? ? [] : [heading, *items.map { |item| "  #{item}" }, ""]
          end
        end
      end
    end
  end
end
