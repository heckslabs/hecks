module Hecks
  module Projector
    module CliProjector
      # The `--help` page of one command or question: what it is, how to call it, what each
      # argument takes and every way it refuses.
      module CommandHelp
        module_function

        # Four independent blocks, concatenated in fixed order: meta, invocation,
        # arguments, refusals.
        def render(program, name, spec, ask: false)
          out = meta_lines(name, spec)
          out.concat(invocation_lines(program, name, spec, ask))
          out.concat(argument_lines(spec))
          out.concat(refusal_lines(spec))
          out.join("\n")
        end

        # The title line and what the call dispatches, reads and who issues it.
        def meta_lines(name, spec)
          out = ["#{name} — #{spec[:summary]}", ""]
          out << "dispatches #{spec[:command]}" if spec[:kind] == :command
          out << "reads #{spec[:command]}"      if spec[:kind] == :query
          out << "issued by #{spec[:role]}" if spec[:role]
          out
        end

        # The call as typed, with one `path=…` per argument.
        def invocation_lines(program, name, spec, ask)
          invocation = ask ? "#{program} query #{name}" : "#{program} #{name}!"
          ["", "  #{invocation}#{spec[:arguments].map { |a| " #{a[:path]}=…" }.join}", ""]
        end

        # One line per argument, its path padded to the longest, then a blank line.
        def argument_lines(spec)
          return [] if spec[:arguments].empty?

          width = spec[:arguments].map { |a| a[:path].length }.max
          lines = spec[:arguments].map do |argument|
            "  #{argument[:path].ljust(width)}  #{argument_notes(argument).join("; ")}"
          end
          lines << ""
        end

        # What an argument takes, in the order help reads it: type, closed set, pattern, default,
        # its own note, then `optional`.
        def argument_notes(argument)
          [argument[:type], *constraint_notes(argument), *trailing_notes(argument)]
        end

        # The closed set, pattern and default an argument declares.
        def constraint_notes(argument)
          notes = []
          notes << "one of #{argument[:enum].join(", ")}" if argument[:enum]
          notes << "matches #{argument[:pattern]}"        if argument[:pattern]
          notes << "defaults to #{argument[:default].inspect}" unless argument[:default].nil?
          notes
        end

        # An argument's own note, then `optional` when it need not be given.
        def trailing_notes(argument)
          notes = []
          notes << argument[:note] if argument[:note]
          notes << "optional" unless argument[:required]
          notes
        end

        # The "refused when" and "refused unless" blocks, each only when it has items.
        def refusal_lines(spec)
          [["refused when:", spec[:refusals]], ["refused unless:", spec[:requirements]]].flat_map do |heading, items|
            Array(items).empty? ? [] : [heading, *items.map { |item| "  #{item}" }, ""]
          end
        end
      end
    end
  end
end
