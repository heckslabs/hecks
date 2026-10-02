require_relative "../naming"

module Hecks
  module Projector
    # Projects a bluebook as its own command-line surface: the verb tree, argument spec
    # and usage text. Nothing executes here; the generic runner (`hecks run`) parses against it.
    #
    # Argument types come from the declared field types, never from guessing at the
    # string: `sequence.value=99` must become 99, and a version "99" must stay a String.
    module CliProjector
      module_function

      # Projects the verb and question tables and the usage text. Commands and queries are
      # separate namespaces (a chapter may declare both under one name); ask a query with `ask`.
      #
      # @param bluebook [Bluebook::Chapter] the booted domain to project
      # @param options [Hash{Symbol => Object}] `:program` (default `"hecks run"`) for the usage
      #   text; `:verb` and `:ask` select one verb's `--help` text; `:names` maps a launcher
      #   name to the command it stands for (`{ "mcp" => "serve_mcp" }`); `:mint_run_keys` makes a
      #   creating verb's `run` key optional, since the launcher mints it
      # @return [Hash{Symbol => Object}] `:verbs`, `:questions`, `:names` (alias tables) and
      #   `:usage` (pre-rendered help text)
      # @raise [Bluebook::DSL::Malformed] if two verbs project to the same command-line name
      def call(bluebook:, options: {})
        verbs     = {}
        questions = {}

        bluebook.aggregates.each { |aggregate| claim_aggregate(verbs, questions, bluebook, aggregate) }

        # A report belongs to the chapter, not an aggregate, so it is addressed
        # `Chapter.Report` (one dot) where a query is `Chapter::Aggregate.Query`.
        bluebook.read_models.each do |model|
          claim(questions, Naming.snake(model.hecks_name), report_spec(bluebook, model))
        end

        mint_run_keys(verbs) if options[:mint_run_keys]

        # The display name is the shortest unambiguous one; both spellings are accepted.
        display_names([verbs, questions], options[:names])

        { verbs: verbs, questions: questions,
          names: { command: aliases(verbs), question: aliases(questions) },
          usage: usage(bluebook, verbs, questions, options) }
      end

      # Claims the verbs and questions of one aggregate and its entities and ports.
      #
      # @param verbs [Hash{String => Hash}] the verb map, mutated in place
      # @param questions [Hash{String => Hash}] the question map, mutated in place
      # @param bluebook [Bluebook::Chapter] the booted domain
      # @param aggregate [Bluebook::Aggregate] the aggregate to claim
      # @return [void]
      def claim_aggregate(verbs, questions, bluebook, aggregate)
        aggregate.commands.each { |c| claim(verbs, name_for(aggregate, c), command_spec(bluebook, aggregate, nil, c)) }
        aggregate.queries.each  { |q| claim(questions, name_for(aggregate, q), query_spec(bluebook, aggregate, nil, q)) }

        aggregate.entities.each do |entity|
          entity.commands.each do |c|
            claim(verbs, name_for(aggregate, c, entity), command_spec(bluebook, aggregate, entity, c))
          end
          entity.queries.each do |q|
            claim(questions, name_for(aggregate, q, entity), query_spec(bluebook, aggregate, entity, q))
          end
        end

        # Port operations dispatch by the same name as a command, so they are verbs too.
        aggregate.ports.each do |port|
          port.operations.each { |o| claim(verbs, name_for(aggregate, o), port_spec(bluebook, aggregate, port, o)) }
        end
      end

      # Sets `:short` on each spec: the last segment when exactly one verb ends in it,
      # else the full name (two aggregates both declaring `Close` keep both spellings).
      #
      # @param specs [Hash{String => Hash}] the verb or question map, mutated in place
      # @return [void]
      def shorten(specs)
        tails = specs.keys.group_by { |name| name.split(".").last }
        specs.each do |name, spec|
          tail = name.split(".").last
          spec[:short] = tails[tail].length == 1 ? tail : name
        end
      end

      # Marks the `run` key of each creating verb `minted`: optional, and never filled by a bare
      # word, since the launcher makes one when it is left out.
      def mint_run_keys(verbs)
        verbs.each_value do |spec|
          next unless spec[:creates]

          spec[:arguments] = spec[:arguments].map do |argument|
            next argument unless argument[:path] == "run.value"

            argument.merge(required: false, minted: true, note: "minted when omitted")
          end
        end
      end

      # Sets the display name of every spec in each map: shortened, then renamed by `names`.
      #
      # @param maps [Array<Hash{String => Hash}>] the verb and question maps, mutated in place
      # @param names [Hash, nil] the chapter's launcher names
      # @return [void]
      def display_names(maps, names)
        maps.each do |specs|
          shorten(specs)
          rename(specs, names)
        end
      end

      # Gives a command the launcher name a chapter's `names` table assigns it.
      #
      # The alias replaces the short name in help, so it is listed once; the spelling it
      # replaced keeps working (`:short_was`, read by `aliases`). A table entry naming no
      # command in `specs` belongs to the other namespace and is skipped.
      #
      # @param specs [Hash{String => Hash}] the verb or question map, mutated in place
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

      # Maps every accepted spelling (full name, `:short` and a renamed command's old short
      # name) to the full name.
      def aliases(specs)
        specs.each_with_object({}) do |(name, spec), map|
          map[name]         = name
          map[spec[:short]] = name
          map[spec[:short_was]] = name if spec[:short_was]
        end
      end

      # Stores `spec` under `name`, refusing a second claim rather than silently
      # keeping whichever verb was walked first.
      #
      # @raise [Bluebook::DSL::Malformed] if `name` is already claimed by another verb
      def claim(verbs, name, spec)
        if verbs.key?(name)
          raise Bluebook::DSL::Malformed,
                "two verbs project to the command-line name #{name.inspect}: " \
                "#{verbs[name][:verb]} and #{spec[:verb]} — rename one"
        end

        verbs[name] = spec
      end

      # The dotted command-line name, `aggregate[.entity].verb`, snake-cased.
      def name_for(aggregate, verb, entity = nil)
        parts = [Naming.snake(aggregate.hecks_name)]
        parts << Naming.snake(entity.hecks_name) if entity
        parts << Naming.snake(verb.hecks_name)
        parts.join(".")
      end

      # The verb's language name, `Chapter::Aggregate[.Entity].Verb`, for help text.
      def fqn(bluebook, aggregate, verb, entity = nil)
        [bluebook.name, "::", aggregate.hecks_name, ".",
         entity ? "#{entity.hecks_name}." : "", verb.hecks_name].join
      end

      # The options that name the record a verb acts on, before its own arguments.
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

        { verb: fqn(bluebook, aggregate, command, entity), kind: :command,
          summary: command.goal, role: command.role, role_gated: !command.role.to_s.empty?,
          group: aggregate.hecks_name, internal: command.role.to_s == "System",
          creates: command.creates?,
          receiver: receiver, legacy_receiver: (receiver == :aggregate ? :id : nil),
          legacy_arguments: legacy_arguments,
          refusals: refusals(command, holder), requirements: requirements(command),
          arguments: arguments }
      end

      # A port operation reads as a verb but reports as a boundary: it creates no
      # record, and an outbound failure is the other side's sentence, so `refusals` is empty.
      def port_spec(bluebook, aggregate, port, operation)
        arguments = receiver_options(:aggregate, aggregate, nil) +
                    operation.attributes.flat_map { |a| options_for(a, aggregate, aggregate) }

        # `Dispatcher#dispatch` looks the head up as a port, so the wire name is
        # `Aggregate.Port.Operation`; the short name (see `shorten`) hides the port.
        { verb: [fqn(bluebook, aggregate, operation).sub(/\.[^.]+\z/, ""), port.name, operation.hecks_name].join("."),
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

        { verb: "#{bluebook.name}.#{model.hecks_name}", kind: :query,
          summary: model.description, arguments: arguments }
      end

      # A question that only reads the aggregate's own records back: it returns no document and
      # filters on nothing but the record's identity ("how one request ended") or its lifecycle
      # status ("every request that was refused"). Each journaled run has such a pair, which a
      # person reads through `hecks <verb> --wait` rather than asking for by name, so the help
      # sets them apart with the bookkeeping verbs. A query that returns a document, or filters
      # on anything else, is a real question. Only an aggregate that journals its own runs (it has
      # system-role commands, the ones `internal` verbs are made of) has such a pair: a release's
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

        { verb: fqn(bluebook, aggregate, query, entity), kind: :query, group: aggregate.hecks_name,
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
        return [scalar_option(path, attribute, optional)] unless value_object

        # The list flag rides on each leaf: without it a repeated flag overwrote the
        # leaf silently, and CliDoor only ever sees a path and a spec.
        fields = value_object.attributes.flat_map do |field|
          nested = value_object_for(field, value_object, aggregate)
          next options_for(field, value_object, aggregate, path, optional) if nested

          scalar_option("#{path}.#{field.name}", field, optional || field.optional?,
                        enum: closed_members(value_object, field))
        end

        return fields unless attribute.list?

        fields.map { |option| option.merge(list: true, note: [option[:note], "repeatable"].compact.join("; ")) }
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

      # The conditions that refuse the verb when they hold, in the chapter's own words: a
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

      # The conditions the verb needs: each `given` states what must hold, so the verb is
      # refused unless it does.
      def requirements(command) = command.givens.map(&:description)

      # Renders the full verb/question table, or one verb's `--help` text when
      # `options[:verb]` names one.
      def usage(bluebook, verbs, questions, options)
        program = options[:program] || "hecks run"
        only    = options[:verb]

        # `options[:ask]` picks the namespace when both hold the name; without it a
        # question's `--help` would print the command sharing its name.
        if only
          pool = options[:ask] ? questions : verbs
          key  = aliases(pool)[only] || (options[:ask] ? nil : aliases(questions)[only])
          spec = pool[key] || questions[key]
          return verb_help(program, spec[:short], spec, ask: options[:ask]) if spec
        end

        width = (verbs.values + questions.values).map { |spec| spec[:short].length }.max.to_i
        out = ["#{bluebook.name} — #{bluebook.vision}", "",
               "  #{program} <verb> [name=value …]        do something",
               "  #{program} ask <question> [name=value …]  read something", ""]

        out << "verbs:"
        out.concat(listing(verbs, width) { |spec| spec[:summary] })
        out << ""
        out << "questions (nothing here changes anything):"
        out.concat(listing(questions, width) { |spec| first_sentence(spec[:summary]) })
        out << ""
        out << "  #{program} <verb> --help       what one verb wants, and every way it refuses"
        out << "  a verb can always be spelled in full — #{example_qualified(verbs)}"
        out.join("\n")
      end

      # The verb or question lines of the help. A domain with more than one aggregate is listed
      # under a heading per aggregate, so related verbs sit together; the bookkeeping a run records
      # about itself (`internal`: system-role commands and port operations) is set apart as names
      # only, since a person never types them. A single-aggregate domain keeps the plain list.
      def listing(specs, width)
        shown, internal = specs.values.partition { |spec| !spec[:internal] }
        groups = shown.group_by { |spec| spec[:group] }
        lines = []
        if groups.length > 1
          groups.each do |group, members|
            lines << "  #{heading(group)}" if group
            members.each { |spec| lines << "    #{spec[:short].ljust(width)}  #{yield(spec)}" }
          end
        else
          shown.each { |spec| lines << "  #{spec[:short].ljust(width)}  #{yield(spec)}" }
        end
        lines.concat(internal_lines(internal)) unless internal.empty?
        lines
      end

      # "LanguageRun" reads "Language": the Run suffix names the journaled-command shape every one of
      # these aggregates shares, so it adds nothing under a heading ("Test suite", "Model check").
      def heading(group)
        words = Naming.snake(group.sub(/Run\z/, "")).tr("_", " ")
        "#{words.capitalize}:"
      end

      # The internal verbs as bare names, wrapped, under one line saying what they are.
      def internal_lines(specs)
        lines = ["  internal — what a run records about itself, named here only (`--help` still works):"]
        line = "   "
        specs.map { |spec| spec[:short] }.each do |name|
          if line.length + name.length + 1 > 98
            lines << line
            line = "   "
          end
          line += " #{name}"
        end
        lines << line
      end

      # One verb whose full spelling differs from its short one, or `""` when none does.
      def example_qualified(verbs)
        name, spec = verbs.find { |key, value| key != value[:short] } || verbs.first
        name ? "#{spec[:short]} is also #{name}" : ""
      end

      # The verb table wants a query description's first sentence; `--help` prints all.
      def first_sentence(text)
        text.to_s.split(/(?<=\.)\s/).first.to_s
      end

      # Four independent blocks, concatenated in fixed order: meta, invocation,
      # arguments, refusals.
      def verb_help(program, name, spec, ask: false)
        out = verb_help_meta_lines(name, spec)
        out.concat(verb_help_invocation_lines(program, name, spec, ask))
        out.concat(verb_help_argument_lines(spec))
        out.concat(verb_help_refusal_lines(spec))
        out.join("\n")
      end

      def verb_help_meta_lines(name, spec)
        out = ["#{name} — #{spec[:summary]}", ""]
        out << "dispatches #{spec[:verb]}" if spec[:kind] == :command
        out << "reads #{spec[:verb]}"      if spec[:kind] == :query
        out << "issued by #{spec[:role]}"  if spec[:role]
        out
      end

      def verb_help_invocation_lines(program, name, spec, ask)
        invocation = ask ? "#{program} ask #{name}" : "#{program} #{name}"
        ["", "  #{invocation}#{spec[:arguments].map { |a| " #{a[:path]}=…" }.join}", ""]
      end

      def verb_help_argument_lines(spec)
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

      def verb_help_refusal_lines(spec)
        [["refused when:", spec[:refusals]], ["refused unless:", spec[:requirements]]].flat_map do |heading, items|
          Array(items).empty? ? [] : [heading, *items.map { |item| "  #{item}" }, ""]
        end
      end
    end
  end
end
