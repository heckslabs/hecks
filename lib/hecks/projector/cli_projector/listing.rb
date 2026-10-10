require_relative "../../naming"

module Hecks
  module Projector
    module CliProjector
      # The command and question lines of the help: grouped under their aggregate, with the
      # bookkeeping a run records about itself set apart.
      module Listing
        # The command or question lines of the help. A domain with more than one aggregate is listed
        # under a heading per aggregate, so related commands sit together; the heading is the prefix
        # every call to them carries, so the lines under it leave it out. The bookkeeping a run
        # records about itself (`internal`: system-role commands and port operations) is left out,
        # since a person never types them; `all` lists them as names only. A single-aggregate
        # domain keeps the plain list, each name in full.
        #
        # @param notes [Hash{String => String}] a line of prose per aggregate, shown
        #   under its heading
        def listing(specs, all: false, notes: {}, &description)
          shown, internal = specs.values.partition { |spec| !spec[:internal] }
          lines = listed_rows(shown, notes, &description)
          lines.concat(internal_lines(internal)) if all && !internal.empty?
          lines
        end

        # The rows of one table: one line per spec, under a heading per aggregate when grouped.
        def listed_rows(shown, notes, &)
          grouped = shown.map { |spec| spec[:group] }.uniq.length > 1
          row = row_formatter(shown.to_h { |spec| [spec, entry_name(spec, grouped)] }, &)
          return shown.map { |spec| row.call(spec, "  ") } unless grouped

          grouped_rows(shown, notes, row)
        end

        # A lambda that renders one spec at an indent: its name padded to the widest, then its text.
        def row_formatter(named, &)
          width = named.values.map(&:length).max.to_i
          ->(spec, indent) { "#{indent}#{named[spec].ljust(width)}  #{yield(spec)}#{alias_note(spec)}" }
        end

        # The rows under a heading per aggregate.
        def grouped_rows(shown, notes, row)
          shown.group_by { |spec| spec[:group] }.flat_map do |group, members|
            [*heading_lines(group, notes), *members.map { |spec| row.call(spec, "    ") }]
          end
        end

        # The lines that open an aggregate's group: its heading, then its note when it has one.
        def heading_lines(group, notes)
          return [] unless group

          ["  #{heading(group)}", *notes[group]&.then { |note| "    #{note}" }]
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
        # is only the command's own name (`init` for `launch.init`) is already in the line.
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
      end
    end
  end
end
