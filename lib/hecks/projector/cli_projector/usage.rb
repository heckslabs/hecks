module Hecks
  module Projector
    module CliProjector
      # The usage text: the command and question tables, or one command's `--help` page.
      module Usage
        module_function

        # Renders the full command/question table, or one command's `--help` text when
        # `options[:command]` names one.
        def render(bluebook, commands, questions, options)
          program = options[:program] || "hecks run"
          help = requested_help(program, commands, questions, options)
          return help if help

          out = ["#{bluebook.name} — #{bluebook.vision}", "",
                 "  #{program} <command>! [name=value …]       do something",
                 "  #{program} query <query> [name=value …]    read something", ""]
          out.concat(tables(commands, questions, all: options[:all], notes: aggregate_notes(bluebook)))
          out.concat(footer(program, commands, questions, options))
          out.join("\n")
        end

        # The lines after the tables: how to ask for one command's help and what a call looks like.
        def footer(program, commands, questions, options)
          out = ["", "  #{program} <command> --help       what one command wants, and every way it refuses"]
          out.concat(all_hint(program, commands, questions)) unless options[:all]
          out << "  a command is called with its aggregate — #{example_qualified(commands)}"
        end

        # The `--help` text of the command `options[:command]` names, or `nil` when none is named
        # or none matches.
        #
        # `options[:ask]` picks the namespace when both hold the name; without it a
        # question's `--help` would print the command sharing its name.
        def requested_help(program, commands, questions, options)
          only = options[:command]
          return unless only

          pool = options[:ask] ? questions : commands
          key  = CliProjector.aliases(pool)[only] || (options[:ask] ? nil : CliProjector.aliases(questions)[only])
          spec = pool[key] || questions[key]
          CommandHelp.render(program, spec[:short], spec, ask: options[:ask]) if spec
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

        # The command or question lines of the help. A domain with more than one aggregate is listed
        # under a heading per aggregate, so related commands sit together; the heading is the prefix
        # every call to them carries, so the lines under it leave it out. The bookkeeping a run
        # records about itself (`internal`: system-role commands and port operations) is left out,
        # since a person never types them; `all` lists them as names only. A single-aggregate
        # domain keeps the plain list, each name in full.
        #
        # @param notes [Hash{String => String}] a line of prose per aggregate, shown under its
        #   heading
        def listing(specs, all: false, notes: {}, &description)
          shown, internal = specs.values.partition { |spec| !spec[:internal] }
          lines = listed_rows(shown, notes, &description)
          lines.concat(internal_lines(internal)) if all && !internal.empty?
          lines
        end

        # The rows of one table: one line per spec, under a heading per aggregate when more than
        # one aggregate is shown.
        def listed_rows(shown, notes, &)
          grouped = shown.map { |spec| spec[:group] }.uniq.length > 1
          texts = row_texts(shown, grouped, &)
          return shown.map { |spec| "  #{texts[spec]}" } unless grouped

          shown.group_by { |spec| spec[:group] }.flat_map do |group, members|
            [*heading_lines(group, notes), *members.map { |spec| "    #{texts[spec]}" }]
          end
        end

        # Each spec's row text, without its indent: the name padded to the longest, then the
        # description and any alias note.
        def row_texts(shown, grouped, &description)
          named = shown.to_h { |spec| [spec, entry_name(spec, grouped)] }
          width = named.values.map(&:length).max.to_i
          named.to_h { |spec, name| [spec, "#{name.ljust(width)}  #{description.call(spec)}#{alias_note(spec)}"] }
        end

        # The lines that open an aggregate's group: its heading, then its note when it has one.
        def heading_lines(group, notes)
          return [] unless group

          ["  #{heading(group)}", *notes[group]&.then { |note| "    #{note}" }]
        end

        # The first sentence of each aggregate's description, keyed by aggregate name; an aggregate
        # with no description has no entry.
        def aggregate_notes(bluebook)
          bluebook.aggregates.to_h { |aggregate| [aggregate.hecks_name, first_sentence(aggregate.description)] }
                  .reject { |_, note| note.empty? }
        end

        # The aggregate's own name as a heading: the prefix of every call to the lines under it.
        def heading(group)
          "#{Naming.snake(group)}:"
        end

        # A spec's name as listed: under its aggregate's heading the aggregate prefix is left out.
        # A command the chapter gives a short name (`mcp`) is listed by its real name, so the
        # heading and the line still spell a call; `alias_note` says the short name.
        def entry_name(spec, grouped)
          name = label(spec, real: true)
          return name unless grouped && spec[:group]

          name.delete_prefix("#{Naming.snake(spec[:group])}.")
        end

        # " (also: mcp!)" for a spec the chapter gave a short name, else nothing. A short name that
        # is only the command's own name (`init` for `door.init`) is already in the line.
        def alias_note(spec)
          return "" if spec[:short_was].nil? || spec[:short_was].split(".").last == spec[:short]

          " (also: #{label(spec)})"
        end

        # A command is written with the `!` that marks it; a query without one.
        # With `real:`, a short name the chapter gave it gives way to the name it was given for.
        def label(spec, real: false)
          name = real && spec.key?(:short_was) ? spec[:short_was] : spec[:short]
          spec[:kind] == :command ? "#{name}!" : name
        end

        # The internal commands as bare names, wrapped, under one line saying what they are.
        def internal_lines(specs)
          lines = ["  internal — what a run records about itself, named here only (`--help` still works):"]
          line = "   "
          specs.map { |spec| label(spec) }.each do |name|
            if line.length + name.length + 1 > 98
              lines << line
              line = "   "
            end
            line += " #{name}"
          end
          lines << line
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
