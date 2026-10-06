require_relative "../naming"

module Hecks
  module Projector
    # Projects a bluebook as its own command-line surface: the command tree, argument spec
    # and usage text. Nothing executes here; the generic runner (`hecks run`) parses against it.
    #
    # Argument types come from the declared field types, never from guessing at the
    # string: `sequence.value=99` must become 99, and a version "99" must stay a String.
    module CliProjector
      module_function

      # Projects the command and question tables and the usage text. Commands and queries are
      # separate namespaces (a chapter may declare both under one name); ask a query with `ask`.
      #
      # @param bluebook [Bluebook::Chapter] the booted domain to project
      # @param options [Hash{Symbol => Object}] `:program` (default `"hecks run"`) for the usage
      #   text; `:command` and `:ask` select one command's `--help` text; `:names` maps a launcher
      #   name to the command it stands for (`{ "mcp" => "serve_mcp" }`); `:mint_run_keys` makes a
      #   creating command's `run` key optional, since the launcher mints it
      # @return [Hash{Symbol => Object}] `:commands`, `:questions`, `:names` (alias tables) and
      #   `:usage` (pre-rendered help text)
      # @raise [Bluebook::DSL::Malformed] if two commands project to the same command-line name
      def call(bluebook:, options: {})
        commands = {}
        questions = {}

        bluebook.aggregates.each { |aggregate| claim_aggregate(commands, questions, bluebook, aggregate) }

        # A report belongs to the chapter, not an aggregate, so it is addressed
        # `Chapter.Report` (one dot) where a query is `Chapter::Aggregate.Query`.
        bluebook.read_models.each do |model|
          claim(questions, Naming.snake(model.hecks_name), report_spec(bluebook, model))
        end

        mint_run_keys(commands) if options[:mint_run_keys]

        # The display name is the shortest unambiguous one; both spellings are accepted.
        display_names([commands, questions], options[:names])

        { commands: commands, questions: questions,
          names: { command: aliases(commands), question: aliases(questions) },
          usage: usage(bluebook, commands, questions, options) }
      end

      # Claims the commands and questions of one aggregate and its entities and ports.
      #
      # @param commands [Hash{String => Hash}] the command map, mutated in place
      # @param questions [Hash{String => Hash}] the question map, mutated in place
      # @param bluebook [Bluebook::Chapter] the booted domain
      # @param aggregate [Bluebook::Aggregate] the aggregate to claim
      # @return [void]
      def claim_aggregate(commands, questions, bluebook, aggregate)
        aggregate.commands.each { |c| claim(commands, name_for(aggregate, c), command_spec(bluebook, aggregate, nil, c)) }
        aggregate.queries.each  { |q| claim(questions, name_for(aggregate, q), query_spec(bluebook, aggregate, nil, q)) }

        aggregate.entities.each do |entity|
          entity.commands.each do |c|
            claim(commands, name_for(aggregate, c, entity), command_spec(bluebook, aggregate, entity, c))
          end
          entity.queries.each do |q|
            claim(questions, name_for(aggregate, q, entity), query_spec(bluebook, aggregate, entity, q))
          end
        end

        # Port operations dispatch by the same name as a command, so they are commands too.
        aggregate.ports.each do |port|
          port.operations.each { |o| claim(commands, name_for(aggregate, o), port_spec(bluebook, aggregate, port, o)) }
        end
      end

      # Sets `:short` on each spec to its full `aggregate.command` name: a command is always
      # called with its aggregate, so adding a command elsewhere never changes what a call means.
      #
      # @param specs [Hash{String => Hash}] the command or query map, mutated in place
      # @return [void]
      def qualify(specs)
        specs.each { |name, spec| spec[:short] = name }
      end

      # Marks the `run` key of each creating command `minted`: optional, and never filled by a bare
      # word, since the launcher makes one when it is left out.
      def mint_run_keys(commands)
        commands.each_value do |spec|
          next unless spec[:creates]

          spec[:arguments] = spec[:arguments].map do |argument|
            next argument unless argument[:path] == "run.value"

            argument.merge(required: false, minted: true, note: "minted when omitted")
          end
        end
      end

      # Sets the display name of every spec in each map: its full name, then renamed by `names`.
      #
      # @param maps [Array<Hash{String => Hash}>] the command and question maps, mutated in place
      # @param names [Hash, nil] the chapter's launcher names
      # @return [void]
      def display_names(maps, names)
        maps.each do |specs|
          qualify(specs)
          rename(specs, names)
        end
      end

      # Gives a command the launcher name a chapter's `names` table assigns it.
      #
      # The alias replaces the short name in help, so it is listed once; the spelling it
      # replaced keeps working (`:short_was`, read by `aliases`). A table entry naming no
      # command in `specs` belongs to the other namespace and is skipped.
      #
      # @param specs [Hash{String => Hash}] the command or question map, mutated in place
      # @param names [Hash{String, Symbol => String, Symbol}, nil] launcher name to command name
      # @return [void]
      # @raise [Bluebook::DSL::Malformed] if a launcher name is already another command's name
      def rename(specs, names)
        Hash(names).each do |launcher_name, command|
          found = specs.find { |key, spec| [key, spec[:short]].include?(command.to_s) }
          next unless found

          taken = specs.values.any? { |spec| spec[:short] == launcher_name.to_s }
          raise Bluebook::DSL::Malformed, "launcher name #{launcher_name.to_s.inspect} is already a command" if taken

          found.last[:short_was] = found.last[:short]
          found.last[:short]     = launcher_name.to_s
        end
      end

      # Maps every accepted spelling (full name, `:short` and a renamed command's old name)
      # to the full name.
      def aliases(specs)
        specs.each_with_object({}) do |(name, spec), map|
          map[name]         = name
          map[spec[:short]] = name
          map[spec[:short_was]] = name if spec[:short_was]
        end
      end

      # Stores `spec` under `name`, refusing a second claim rather than silently
      # keeping whichever command was walked first.
      #
      # @raise [Bluebook::DSL::Malformed] if `name` is already claimed by another command
      def claim(commands, name, spec)
        if commands.key?(name)
          raise Bluebook::DSL::Malformed,
                "two commands project to the command-line name #{name.inspect}: " \
                "#{commands[name][:command]} and #{spec[:command]} — rename one"
        end

        commands[name] = spec
      end

      # The dotted command-line name, `aggregate[.entity].command`, snake-cased.
      def name_for(aggregate, command, entity = nil)
        parts = [Naming.snake(aggregate.hecks_name)]
        parts << Naming.snake(entity.hecks_name) if entity
        parts << Naming.snake(command.hecks_name)
        parts.join(".")
      end

      # The command's language name, `Chapter::Aggregate[.Entity].Verb`, for help text.
      def fqn(bluebook, aggregate, command, entity = nil)
        [bluebook.name, "::", aggregate.hecks_name, ".",
         entity ? "#{entity.hecks_name}." : "", command.hecks_name].join
      end

      # The options that name the record a command acts on, before its own arguments.
      # `nil` (a creating command) takes none: there is no record yet.
      # Ports always pass `:aggregate`, since a port is declared on an aggregate.
      def receiver_options(receiver, aggregate, entity)
        case receiver
        when :entity
          [
            { path: "to.aggregate", type: "String", required: true,
              note: "id of the #{aggregate.hecks_name} holding the #{entity.hecks_name}" },
            { path: "to.entity", type: "String", required: true,
              note: "id of the #{entity.hecks_name} to act on" }
          ]
        when :aggregate
          [{ path: "to", type: "String", required: true,
             note: "id of the #{aggregate.hecks_name} to act on" }]
        else
          []
        end
      end

      def command_spec(bluebook, aggregate, entity, command)
        holder    = entity || aggregate
        arguments = command.attributes.flat_map { |a| options_for(a, holder, aggregate) }
        receiver  = if entity
                      :entity
                    else
                      (command.creates? ? nil : :aggregate)
                    end

        # The receiver paths stay in the projected option list so the request is complete;
        # CommandRequest strips them before building `with:`. `id=...` is still accepted
        # for aggregate receivers but hidden from help, which teaches only `to=...`.
        arguments = receiver_options(receiver, aggregate, entity) + arguments
        legacy_arguments = receiver == :aggregate ? [{ path: "id", type: "String", required: true }] : []

        { command: fqn(bluebook, aggregate, command, entity), kind: :command,
          summary: command.goal, role: command.role, role_gated: !command.role.to_s.empty?,
          group: aggregate.hecks_name, internal: command.role.to_s == "System",
          creates: command.creates?,
          receiver: receiver, legacy_receiver: (receiver == :aggregate ? :id : nil),
          legacy_arguments: legacy_arguments,
          refusals: refusals(command, holder), requirements: requirements(command),
          arguments: arguments }
      end

      # A port operation reads as a command but reports as a boundary: it creates no
      # record, and an outbound failure is the other side's sentence, so `refusals` is empty.
      def port_spec(bluebook, aggregate, port, operation)
        arguments = receiver_options(:aggregate, aggregate, nil) +
                    operation.attributes.flat_map { |a| options_for(a, aggregate, aggregate) }

        # `Dispatcher#dispatch` looks the head up as a port, so the wire name is
        # `Aggregate.Port.Operation`; the launcher name hides the port.
        { command: [fqn(bluebook, aggregate, operation).sub(/\.[^.]+\z/, ""), port.name, operation.hecks_name].join("."),
          kind: :command, creates: false, receiver: :aggregate, refusals: [],
          # `role:` is help text only; port dispatch never reaches the role check,
          # so `role_gated` is always false here.
          role: if operation.outbound?
                  "#{aggregate.hecks_name} asking #{port.name}"
                else
                  "#{port.name} telling #{aggregate.hecks_name}"
                end,
          role_gated: false, group: aggregate.hecks_name, internal: true,
          summary: port_summary(port, operation), arguments: arguments }
      end

      # Names both endings of a port operation, since `--help` is where a caller
      # learns that e.g. a spec run answers `SpecsCompleted` even when the suite is red.
      def port_summary(port, operation)
        return "#{port.name} reports it; emits #{operation.emits.join(', ')}" unless operation.outbound?

        "Ask #{port.name} — answers #{operation.answers}, refuses #{operation.refuses}"
      end

      # A rootless report takes nothing; a rooted one takes the id of the record it
      # is a view of, under the name the model gave that reference.
      def report_spec(bluebook, model)
        arguments =
          if model.reference_target
            [{ path: model.reference_name.to_s, type: "String", required: true,
               note: "id of the #{model.reference_target} this is a view of" }]
          else
            []
          end

        { command: "#{bluebook.name}.#{model.hecks_name}", kind: :query,
          summary: model.description, arguments: arguments }
      end

      # A question that only reads the aggregate's own records back: it returns no document and
      # filters on nothing but the record's identity ("how one request ended") or its lifecycle
      # status ("every request that was refused"). Each journaled run has such a pair, which a
      # person reads through `hecks <command> --wait` rather than asking for by name, so the help
      # sets them apart with the bookkeeping commands. A query that returns a document, or filters
      # on anything else, is a real question. Only an aggregate that journals its own runs (it has
      # system-role commands, the ones `internal` commands are made of) has such a pair: a release's
      # "every version that was shipped" is a question worth asking by name.
      def bookkeeping_query?(aggregate, query)
        return false if query.returns || query.wheres.empty?
        return false unless aggregate.commands.any? { |command| command.role.to_s == "System" }

        own = Array(aggregate.identified_by).map(&:to_s) + [aggregate.lifecycle&.field.to_s]
        query.wheres.all? { |clause| own.include?(clause.field.to_s) }
      end

      def query_spec(bluebook, aggregate, entity, query)
        arguments = Array(query.to_h[:attributes]).flat_map do |declared|
          attribute = query.attributes.find { |a| a.name.to_s == declared[:name].to_s }
          attribute ? options_for(attribute, entity || aggregate, aggregate) : []
        end

        { command: fqn(bluebook, aggregate, query, entity), kind: :query, group: aggregate.hecks_name,
          internal: entity.nil? && bookkeeping_query?(aggregate, query),
          summary: query.description, arguments: arguments, returns: query.returns }
      end

      # Flattens an attribute into one option per leaf field. A value object becomes
      # dotted options (`--commit.value`), recursing into nested value objects so
      # `{ cents: 1500 }` is never sent as the string "1500".
      #
      # @param attribute [Bluebook::Attribute] the field being projected
      # @param holder [Bluebook::Aggregate, Bluebook::Entity, Class] what declares `attribute`
      # @param aggregate [Bluebook::Aggregate] the top-level aggregate, kept across recursion
      # @param prefix [String, nil] the dotted path built so far
      # @param optional [Boolean, nil] whether an enclosing field already makes this one optional
      # @return [Array<Hash{Symbol => Object}>] one option spec per leaf field
      def options_for(attribute, holder, aggregate, prefix = nil, optional = nil)
        path = [prefix, attribute.name].compact.join(".")
        optional ||= attribute.optional?
        return [reference_option(attribute)] if attribute.reference?

        value_object = value_object_for(attribute, holder, aggregate)
        return with_declared_default([scalar_option(path, attribute, optional)], attribute) unless value_object

        # The list flag rides on each leaf: without it a repeated flag overwrote the
        # leaf silently, and CliDoor only ever sees a path and a spec.
        fields = value_object.attributes.flat_map do |field|
          nested = value_object_for(field, value_object, aggregate)
          next options_for(field, value_object, aggregate, path, optional) if nested

          scalar_option("#{path}.#{field.name}", field, optional || field.optional?,
                        enum: closed_members(value_object, field))
        end
        fields = with_declared_default(fields, attribute)

        return fields unless attribute.list?

        fields.map { |option| option.merge(list: true, note: [option[:note], "repeatable"].compact.join("; ")) }
      end

      # Shows the default the attribute itself declares (`attribute :runs, Count, default: 30`) on
      # the leaf it fills: the matching field for a hash default, the lone field for a bare one.
      # An argument with a default is never required, since the runtime fills it when omitted.
      #
      # @param options [Array<Hash{Symbol => Object}>] the attribute's leaf option specs
      # @param attribute [Object] the attribute, which may declare a default
      # @return [Array<Hash{Symbol => Object}>] `options`, with the default shown where it lands
      def with_declared_default(options, attribute)
        declared = attribute.default if attribute.respond_to?(:default)
        return options if declared.nil?

        options.map do |option|
          leaf = option[:path].split(".").last
          value = declared.is_a?(Hash) ? declared.fetch(leaf.to_sym) { declared[leaf] } : (declared if options.one?)
          value.nil? ? option : option.merge(default: value, required: false)
        end
      end

      def reference_option(attribute)
        { path: attribute.name.to_s, type: "String", required: !attribute.optional?,
          note: "id of a #{attribute.type.target_name}" }
      end

      # A `list_of` scalar carries `list: true, words: true`: the launcher reads a comma-separated
      # value or a repeated name as the list's elements, since the runtime refuses a lone scalar.
      def scalar_option(path, field, optional, enum: [])
        option = { path: path, type: field.type.to_s, required: !optional }
        option.merge!(list: true, words: true, note: "list: comma-separated or repeated") if field.list?
        option[:enum]    = enum          unless enum.empty?
        option[:pattern] = field.pattern if field.respond_to?(:pattern) && field.pattern
        option[:default] = field.default if field.respond_to?(:default) && !field.default.nil?
        option
      end

      # The values a `one_of` value object's field is closed to, or `[]` for an open one.
      def closed_members(value_object, field)
        return [] unless value_object.closed_set?

        value_object.members.filter_map { |member| member[field.name] }.uniq
      end

      # The `Bluebook::ValueObject` subclass an attribute's type names, searching
      # `holder` then `aggregate`, or `nil` for a plain scalar.
      def value_object_for(attribute, holder, aggregate)
        [holder, aggregate].compact.each do |scope|
          next unless scope.respond_to?(:value_objects)

          found = scope.value_objects.find { |v| v.hecks_name == attribute.type.to_s }
          return found if found
        end
        nil
      end

      # The conditions that refuse the command when they hold, in the chapter's own words: a
      # lifecycle state mismatch and a missing referenced record per `reference_to`.
      def refusals(command, holder)
        out = []
        lifecycle = holder.lifecycle
        froms = lifecycle && lifecycle.transitions.filter_map do |name, transition|
          Array(transition.from) if name.to_s == command.hecks_name
        end.flatten.uniq
        out << "#{lifecycle.field} is not #{froms.join(' or ')}" if froms && !froms.empty?
        out += command.attributes.select(&:reference?).map { |r| "no #{r.type.target_name} has that #{r.name}" }
        out
      end

      # The conditions the command needs: each `given` states what must hold, so the command is
      # refused unless it does.
      def requirements(command) = command.givens.map(&:description)

      # Renders the full command/question table, or one command's `--help` text when
      # `options[:command]` names one.
      def usage(bluebook, commands, questions, options)
        program = options[:program] || "hecks run"
        only    = options[:command]

        # `options[:ask]` picks the namespace when both hold the name; without it a
        # question's `--help` would print the command sharing its name.
        if only
          pool = options[:ask] ? questions : commands
          key  = aliases(pool)[only] || (options[:ask] ? nil : aliases(questions)[only])
          spec = pool[key] || questions[key]
          return command_help(program, spec[:short], spec, ask: options[:ask]) if spec
        end

        out = ["#{bluebook.name} — #{bluebook.vision}", "",
               "  #{program} <command>! [name=value …]       do something",
               "  #{program} query <query> [name=value …]    read something", ""]
        shown = [CliAudience.without_hidden(commands, options[:hide]),
                 CliAudience.without_hidden(questions, options[:hide])]
        out.concat(tables(*shown, all: options[:all], notes: aggregate_notes(bluebook)))
        out.concat(CliAudience.chapter_lines(program, options[:chapters]))
        out << ""
        out << "  #{program} <command> --help       what one command wants, and every way it refuses"
        out.concat(all_hint(program, *shown)) unless options[:all]
        out.concat(CliAudience.maintainer_hint(program, commands.size + questions.size - shown.sum(&:size)))
        out << "  a command is called with its aggregate — #{example_qualified(shown.first)}"
        out.join("\n")
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
      # @param notes [Hash{String => String}] a line of prose per aggregate, shown under its heading
      def listing(specs, all: false, notes: {}, &description)
        shown, internal = specs.values.partition { |spec| !spec[:internal] }
        grouped = shown.map { |spec| spec[:group] }.uniq.length > 1
        named = shown.to_h { |spec| [spec, entry_name(spec, grouped)] }
        lines = listed_rows(shown, named, grouped, notes, &description)
        lines.concat(internal_lines(internal)) if all && !internal.empty?
        lines
      end

      # The rows of one table: one line per spec, under a heading per aggregate when grouped.
      def listed_rows(shown, named, grouped, notes, &description)
        width = named.values.map(&:length).max.to_i
        row = ->(spec, indent) { "#{indent}#{named[spec].ljust(width)}  #{description.call(spec)}#{alias_note(spec)}" }
        return shown.map { |spec| row.call(spec, "  ") } unless grouped

        shown.group_by { |spec| spec[:group] }.flat_map do |group, members|
          [*heading_lines(group, notes), *members.map { |spec| row.call(spec, "    ") }]
        end
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

      # Four independent blocks, concatenated in fixed order: meta, invocation,
      # arguments, refusals.
      def command_help(program, name, spec, ask: false)
        out = command_help_meta_lines(name, spec)
        out.concat(command_help_invocation_lines(program, name, spec, ask))
        out.concat(command_help_argument_lines(spec))
        out.concat(command_help_refusal_lines(spec))
        out.join("\n")
      end

      def command_help_meta_lines(name, spec)
        out = ["#{name} — #{spec[:summary]}", ""]
        out << "dispatches #{spec[:command]}" if spec[:kind] == :command
        out << "reads #{spec[:command]}"      if spec[:kind] == :query
        out << "issued by #{spec[:role]}" if spec[:role]
        out
      end

      def command_help_invocation_lines(program, name, spec, ask)
        invocation = ask ? "#{program} query #{name}" : "#{program} #{name}!"
        ["", "  #{invocation}#{spec[:arguments].map { |a| " #{a[:path]}=…" }.join}", ""]
      end

      def command_help_argument_lines(spec)
        return [] if spec[:arguments].empty?

        width = spec[:arguments].map { |a| a[:path].length }.max
        lines = spec[:arguments].map do |argument|
          notes = []
          notes << argument[:type]
          notes << "one of #{argument[:enum].join(', ')}" if argument[:enum]
          notes << "matches #{argument[:pattern]}"        if argument[:pattern]
          notes << "defaults to #{argument[:default].inspect}" unless argument[:default].nil?
          notes << argument[:note]                        if argument[:note]
          notes << "optional"                             unless argument[:required]
          "  #{argument[:path].ljust(width)}  #{notes.join('; ')}"
        end
        lines << ""
      end

      def command_help_refusal_lines(spec)
        [["refused when:", spec[:refusals]], ["refused unless:", spec[:requirements]]].flat_map do |heading, items|
          Array(items).empty? ? [] : [heading, *items.map { |item| "  #{item}" }, ""]
        end
      end
    end
  end
end
