require_relative "../../naming"

module Hecks
  module Projector
    module CliProjector
      # The usage text of a projection: the command and query tables, or one command's help.
      module Usage
        # Renders the full command/question table, or one command's `--help` text when
        # `options[:command]` names one.
        def usage(bluebook, commands, questions, options)
          program = options[:program] || "hecks run"

          requested_help(program, commands, questions, options) ||
            full_usage(bluebook, commands, questions, options, program)
        end

        # The `--help` text of the command named by `options[:command]`, or `nil` when none is
        # asked for or the name matches nothing.
        def requested_help(program, commands, questions, options)
          only = options[:command]
          return unless only

          spec = help_spec(only, commands, questions, options[:ask])
          command_help(program, spec[:short], spec, ask: options[:ask]) if spec
        end

        # `ask` picks the namespace when both hold the name; without it a
        # question's `--help` would print the command sharing its name.
        def help_spec(name, commands, questions, ask)
          pool = ask ? questions : commands
          key  = aliases(pool)[name] || (ask ? nil : aliases(questions)[name])
          pool[key] || questions[key]
        end

        # The whole help: the two tables, the chapters, then the hints.
        def full_usage(bluebook, commands, questions, options, program)
          shown = [CliAudience.without_hidden(commands, options[:hide]),
                   CliAudience.without_hidden(questions, options[:hide])]
          [usage_header(bluebook, program),
           tables(*shown, all: options[:all], notes: aggregate_notes(bluebook)),
           CliAudience.chapter_lines(program, options[:chapters]),
           usage_footer(program, shown, options, left_out(commands, questions, shown))].flatten(1).join("\n")
        end

        # How many commands and queries the audience's `hide` list left out of `shown`.
        def left_out(commands, questions, shown)
          commands.size + questions.size - shown.sum(&:size)
        end

        # The chapter's vision and the two ways to call it.
        def usage_header(bluebook, program)
          ["#{bluebook.name} — #{bluebook.vision}", "",
           "  #{program} <command>! [name=value …]       do something",
           "  #{program} query <query> [name=value …]    read something", ""]
        end

        # The pointers after the tables: `--help`, `--all`, `--maintainer` and an example call.
        def usage_footer(program, shown, options, hidden_count)
          out = ["", "  #{program} <command> --help       what one command wants, and every way it refuses"]
          out.concat(all_hint(program, *shown)) unless options[:all]
          out.concat(CliAudience.maintainer_hint(program, hidden_count))
          out << "  a command is called with its aggregate — #{example_qualified(shown.first)}"
        end

        # The commands table then the queries table.
        def tables(commands, questions, all:, notes:)
          ["commands:", *listing(commands, all: all, notes: notes) { |spec| spec[:summary] }, "",
           "queries (nothing here changes anything):",
           *listing(questions, all: all, notes: notes) { |spec| first_sentence(spec[:summary]) }]
        end

        # The line saying the internal commands and queries were left out and how to list them,
        # or no line when there are none.
        def all_hint(program, commands, questions)
          hidden = (commands.values + questions.values).count { |spec| spec[:internal] }
          return [] if hidden.zero?

          ["  #{program} --all                  also list the #{hidden} internal commands and queries"]
        end

        # The first sentence of each aggregate's description, keyed by aggregate name; an aggregate
        # with no description has no entry.
        def aggregate_notes(bluebook)
          bluebook.aggregates.to_h { |aggregate| [aggregate.hecks_name, first_sentence(aggregate.description)] }
                  .reject { |_, note| note.empty? }
        end

        # An example call, `aggregate.command!`, from the first command, or `""` when there is none.
        def example_qualified(commands)
          name = commands.keys.first
          name ? "#{name}!" : ""
        end

        # The command table wants a query description's first sentence; `--help` prints all.
        def first_sentence(text)
          text.to_s.split(/(?<=\.)\s/).first.to_s
        end
      end
    end
  end
end
