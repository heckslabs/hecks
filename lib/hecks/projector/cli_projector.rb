require_relative "../naming"

module Hecks
  module Projector
    # A BLUEBOOK, PROJECTED AS ITS OWN COMMAND-LINE SURFACE.
    #
    # Every verb a domain declares is a subcommand; every argument is an
    # option whose TYPE, whose admitted values and whose required-ness are
    # already stated in the chapter. A hand-written CLI restates all of it and
    # then drifts — and the first thing to drift is the help text, which is the
    # only part anybody reads.
    #
    # WHAT IS PROJECTED, AND WHAT IS NOT. This answers the SURFACE — the verb
    # tree, the argument spec, the usage text — and nothing executes here. One
    # small generic runner (`bin/run`) boots a domain, asks for this, parses
    # against it and dispatches.
    #
    # The alternative was generating an executable per domain, which is what
    # `bin/project_rust` does for a whole runtime and would be the more
    # spectacular version of this. It was not taken: a generated program is a
    # second copy of the dispatch logic, and it needs regenerating on every
    # bluebook edit — a second tax beside the era gate, paid for a file nobody
    # reads. Projecting the surface keeps one dispatcher and a help text that
    # cannot be stale, because it is computed at the moment it is printed.
    #
    # THE TYPING IS THE POINT. A CLI hands everything over as a String.
    # `sequence.value=99` has to become the Integer 99 or the runtime refuses
    # it, and the only honest place to learn that is the value object's own
    # declared field type. A CLI that guessed — "it looks like a number" —
    # would send 99 for a version string of "99" and be wrong in a way nobody
    # could see.
    module CliProjector
      module_function

      # TWO NAMESPACES, NOT ONE — `{ verbs:, questions:, usage: }`.
      #
      # A chapter may legally declare a command and a query of one name: the
      # language namespaces them and `Banking::Account.Open` is both, in the
      # corpus, today. A single flat list of subcommands has to pick one, and
      # picking silently is how `Ticket.Filed` sat undetected in this
      # repository for a day.
      #
      # So a question is asked with `ask`: `bin/run ask account.open`. It is
      # this codebase own word — `Query::AskOption`, "the ask" — it is
      # shell-safe where a `?` suffix would be eaten by globbing, and it makes
      # the collision impossible rather than detected. It also reads as what it
      # is: everything under `ask` changes nothing.
      def call(bluebook:, options: {})
        verbs     = {}
        questions = {}

        bluebook.aggregates.each do |aggregate|
          aggregate.commands.each { |c| claim(verbs, name_for(aggregate, c), command_spec(bluebook, aggregate, nil, c)) }
          aggregate.queries.each  { |q| claim(questions, name_for(aggregate, q), query_spec(bluebook, aggregate, nil, q)) }

          aggregate.entities.each do |entity|
            entity.commands.each { |c|
              claim(verbs, name_for(aggregate, c, entity), command_spec(bluebook, aggregate, entity, c))
            }
            entity.queries.each { |q|
              claim(questions, name_for(aggregate, q, entity), query_spec(bluebook, aggregate, entity, q))
            }
          end

          # A PORT IS A VERB TOO, and leaving it off the map was a real gap
          # rather than a tasteful omission. The runtime has always dispatched
          # a port operation by exactly the same name as a command — the
          # projection simply never listed one, so `run_specs` and `file`
          # answered "no such verb" while working perfectly through Ruby.
          #
          # It matters most for the caller with no other door. An agent that
          # may not shell out reaches this domain ONLY through the projected
          # CLI, and a port it cannot see is a capability it does not have.
          aggregate.ports.each do |port|
            port.operations.each { |o| claim(verbs, name_for(aggregate, o), port_spec(bluebook, aggregate, port, o)) }
          end
        end

        # A REPORT IS A QUESTION TOO, and leaving it off was the same gap the
        # ports had: `Dispatcher#query` has always answered `Domain.ReportName`,
        # the projection simply never listed one — so the composed reads worked
        # from Ruby and did not exist for anybody whose only door is the command
        # line.
        #
        # It matters most for exactly what a report is FOR. Every other question
        # here answers with rows and leaves the arithmetic to the reader; a
        # `group_by` report is the one that counts. An agent that cannot reach
        # it can list bugs all day and never answer "how are we doing".
        #
        # ONE DOT, NOT TWO — a report belongs to the chapter rather than to any
        # aggregate (that is what rootless means), so it is addressed
        # `QualityControl.BugsByStatus` where a query is
        # `QualityControl::Bug.Queue`. `Dispatcher#query` splits on precisely
        # that difference.
        bluebook.read_models.each do |model|
          claim(questions, Naming.snake(model.hecks_name), report_spec(bluebook, model))
        end

        # THE SHORT SPELLING, WHERE IT CANNOT BE AMBIGUOUS. `pizzas
        # create_pizza` rather than `pizzas order.create_pizza` — the
        # aggregate is worth typing only when two of them declare the same
        # verb, and in a one-aggregate domain it never is. Both spellings are
        # always accepted; `names` maps every accepted one to its canonical
        # key, and the display name is the shortest that is unambiguous.
        shorten(verbs)
        shorten(questions)

        { verbs: verbs, questions: questions,
          names: { command: aliases(verbs), question: aliases(questions) },
          usage: usage(bluebook, verbs, questions, options) }
      end

      # A last segment is claimed only if exactly one verb ends in it. Two
      # aggregates declaring `Close` keep `customer.close` and `account.close`,
      # which is the honest answer — a CLI that picked one would be choosing
      # for the caller.
      def shorten(specs)
        tails = specs.keys.group_by { |name| name.split(".").last }
        specs.each do |name, spec|
          tail = name.split(".").last
          spec[:short] = tails[tail].length == 1 ? tail : name
        end
      end

      def aliases(specs)
        specs.each_with_object({}) do |(name, spec), map|
          map[name]         = name
          map[spec[:short]] = name
        end
      end

      # A NAME IS CLAIMED ONCE. A command and a query of one name are legal in
      # a chapter — the language namespaces them — and ambiguous as
      # subcommands. Refused here rather than silently resolving to whichever
      # was walked first, which is how `Ticket.Filed` (a command) and
      # `Ticket.Filed` (a query) sat undetected until something flattened them.
      def claim(verbs, name, spec)
        if verbs.key?(name)
          raise Bluebook::DSL::Malformed,
                "two verbs project to the command-line name #{name.inspect}: " \
                "#{verbs[name][:verb]} and #{spec[:verb]} — rename one"
        end

        verbs[name] = spec
      end

      def name_for(aggregate, verb, entity = nil)
        parts = [Naming.snake(aggregate.hecks_name)]
        parts << Naming.snake(entity.hecks_name) if entity
        parts << Naming.snake(verb.hecks_name)
        parts.join(".")
      end

      def fqn(bluebook, aggregate, verb, entity = nil)
        [bluebook.name, "::", aggregate.hecks_name, ".",
         entity ? "#{entity.hecks_name}." : "", verb.hecks_name].join
      end

      # ── one verb ──────────────────────────────────────────────────────

      def command_spec(bluebook, aggregate, entity, command)
        holder    = entity || aggregate
        arguments = command.attributes.flat_map { |a| options_for(a, holder, aggregate) }
        receiver  = if entity
                      :entity
                    else
                      (command.creates? ? nil : :aggregate)
                    end
        legacy_arguments = []

        # THE RECEIVER IS NOT A COMMAND ARGUMENT. An aggregate command names
        # its record through to; an entity command needs both the aggregate
        # record and the entity element within it. Keeping those paths in the
        # projected option list makes the human-facing request complete while
        # CommandRequest can remove them before it builds with: from the
        # command's declared facts.
        #
        # Existing aggregate scripts may still spell the receiver id=... .
        # That alias is deliberately hidden from help and recorded separately
        # as legacy_arguments; new help and examples teach only to=... .
        if entity
          arguments = [
            { path: "to.aggregate", type: "String", required: true,
              note: "id of the #{aggregate.hecks_name} holding the #{entity.hecks_name}" },
            { path: "to.entity", type: "String", required: true,
              note: "id of the #{entity.hecks_name} to act on" }
          ] + arguments
        elsif receiver == :aggregate
          arguments = [{ path: "to", type: "String", required: true,
                         note: "id of the #{aggregate.hecks_name} to act on" }] + arguments
          legacy_arguments = [{ path: "id", type: "String", required: true }]
        end

        { verb: fqn(bluebook, aggregate, command, entity), kind: :command,
          summary: command.goal, role: command.role, creates: command.creates?,
          receiver: receiver, legacy_receiver: (receiver == :aggregate ? :id : nil),
          legacy_arguments: legacy_arguments,
          refusals: refusals(command, holder), arguments: arguments }
      end

      # A PORT OPERATION READS AS A VERB BUT REPORTS AS A BOUNDARY.
      #
      # `creates: false` because it makes no record, and `refusals: []`
      # because it has none in the sense every other verb means: a command's
      # refusals are sentences the chapter will say back to you, and an
      # outbound operation's failure is somebody else's sentence, unknowable
      # from here.
      #
      # THE SUMMARY NAMES BOTH ENDINGS, which is the one thing a caller most
      # needs and cannot infer. `run_specs` looks like it either works or
      # errors; what it actually does is answer `SpecsCompleted` even when the
      # suite is red, and refuse only when rspec could not run. Somebody
      # reading `--help` should not have to open the hecksagon to find that
      # out.
      def port_spec(bluebook, aggregate, port, operation)
        arguments = receiver_options(:aggregate, aggregate, nil) +
                    operation.attributes.flat_map { |a| options_for(a, aggregate, aggregate) }

        # THE WIRE NAME CARRIES THE PORT, THE TYPED NAME DOES NOT.
        #
        # `Dispatcher#dispatch` splits a verb into head and sub and looks the
        # head up as a port, so a port operation is addressed
        # `Aggregate.Port.Operation` — three parts where a command has two.
        # But nobody should have to type `sweep.toolchain.run_specs`: which
        # port a verb goes out through is wiring, and the caller's business is
        # what they want done. So the projection spells the verb in full and
        # names it short, which is the same split `shorten` already makes.
        { verb: [fqn(bluebook, aggregate, operation).sub(/\.[^.]+\z/, ""), port.name, operation.hecks_name].join("."),
          kind: :command, creates: false, receiver: :aggregate, refusals: [],
          role: operation.outbound? ? "#{aggregate.hecks_name} asking #{port.name}" : "#{port.name} telling #{aggregate.hecks_name}",
          summary: port_summary(port, operation), arguments: arguments }
      end

      def port_summary(port, operation)
        return "#{port.name} reports it; emits #{operation.emits.join(', ')}" unless operation.outbound?

        "Ask #{port.name} — answers #{operation.answers}, refuses #{operation.refuses}"
      end

      # A ROOTLESS REPORT TAKES NOTHING; a rooted one takes the id of the
      # record it is a view of, under the name the model gave that reference.
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

      def query_spec(bluebook, aggregate, entity, query)
        arguments = Array(query.to_h[:attributes]).flat_map do |declared|
          attribute = query.attributes.find { |a| a.name.to_s == declared[:name].to_s }
          attribute ? options_for(attribute, entity || aggregate, aggregate) : []
        end

        { verb: fqn(bluebook, aggregate, query, entity), kind: :query,
          summary: query.description, arguments: arguments }
      end

      # ── one argument, flattened ───────────────────────────────────────

      # A VALUE OBJECT BECOMES ONE OPTION PER FIELD, dotted. `commit` typed
      # `CommitRef` is `--commit.value`, because that is the shape the runtime
      # wants and a flat `--commit` would have to guess which field it meant.
      # Single-field value objects — almost all of them — read fine either way,
      # and the runner accepts the short form for exactly those.
      # RECURSIVE, AND IT HAS TO BE. A value object may hold another one —
      # pizzas' `Pizza` holds a `Price` and a `Size` — so stopping after one
      # level produced `pizza.price_cents=1500` and sent the STRING "1500"
      # where `{ cents: 1500 }` belonged.
      #
      # The runtime took it. `qa/FINDINGS.md` #2 is exactly that gap —
      # `Value::Coercion.build` does not validate nested value objects — so a
      # one-level CLI is not merely inconvenient, it is a machine for writing
      # malformed records into a real store, which is what it did on its first
      # run against the pizzas database.
      def options_for(attribute, holder, aggregate, prefix = nil, optional = nil)
        path     = [prefix, attribute.name].compact.join(".")
        optional = optional || attribute.optional?
        return [reference_option(attribute)] if attribute.reference?

        value_object = value_object_for(attribute, holder, aggregate)
        return [scalar_option(path, attribute, optional)] unless value_object

        # A LIST SAYS SO, ALL THE WAY DOWN TO ITS LEAVES.
        #
        # Without this a `list_of(Tag)` projected exactly like a single Tag:
        # one option, `tags.value`, indistinguishable from a scalar. So the
        # help said to pass one, `CliDoor#bury` overwrote the leaf each time,
        # and passing two tags stored the second and lost the first WITHOUT
        # SAYING ANYTHING. A missing argument is refused loudly; a forgotten
        # one is not, which makes it the more expensive of the two by far.
        #
        # The flag is carried on the leaf rather than kept beside the
        # attribute because the leaf is all `CliDoor` ever sees — it is handed
        # a path and a spec, and reuniting them with the attribute that
        # produced them would be a lookup that exists only to answer this.
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

      def scalar_option(path, field, optional, enum: [])
        option = { path: path, type: field.type.to_s, required: !optional }
        option[:enum]    = enum          unless enum.empty?
        option[:pattern] = field.pattern if field.respond_to?(:pattern) && field.pattern
        option[:default] = field.default if field.respond_to?(:default) && !field.default.nil?
        option
      end

      def closed_members(value_object, field)
        return [] unless value_object.closed_set?

        value_object.members.filter_map { |member| member[field.name] }.uniq
      end

      def value_object_for(attribute, holder, aggregate)
        [holder, aggregate].compact.each do |scope|
          next unless scope.respond_to?(:value_objects)

          found = scope.value_objects.find { |v| v.hecks_name == attribute.type.to_s }
          return found if found
        end
        nil
      end

      # Every way this verb can say no, in the chapter's own words — printed
      # by `--help` before the caller spends a dispatch finding out.
      def refusals(command, holder)
        out = []
        lifecycle = holder.lifecycle
        froms = lifecycle && lifecycle.transitions.filter_map do |name, transition|
          Array(transition.from) if name.to_s == command.hecks_name
        end.flatten.uniq
        out << "#{lifecycle.field} is not #{froms.join(' or ')}" if froms && !froms.empty?
        out += command.attributes.select(&:reference?).map { |r| "no #{r.type.target_name} has that #{r.name}" }
        out + command.givens.map(&:description)
      end

      # ── the help ──────────────────────────────────────────────────────

      def usage(bluebook, verbs, questions, options)
        program = options[:program] || "bin/run"
        only    = options[:verb]

        # WHICH NAMESPACE, when both hold the name. `options[:ask]` says so;
        # without it a `--help` for a question would print the command that
        # shares its name, which banking has and which is how this was found.
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
        verbs.each_value { |spec| out << "  #{spec[:short].ljust(width)}  #{spec[:summary]}" }
        out << ""
        out << "questions (nothing here changes anything):"
        questions.each_value { |spec| out << "  #{spec[:short].ljust(width)}  #{first_sentence(spec[:summary])}" }
        out << ""
        out << "  #{program} <verb> --help       what one verb wants, and every way it refuses"
        out << "  a verb can always be spelled in full — #{example_qualified(verbs)}"
        out.join("\n")
      end

      def example_qualified(verbs)
        name, spec = verbs.find { |key, value| key != value[:short] } || verbs.first
        name ? "#{spec[:short]} is also #{name}" : ""
      end

      # A QUERY's `description` is written as a paragraph — it argues for why
      # the list is worth reading. A verb table wants the first sentence of
      # that argument; `--help` still prints the whole thing.
      def first_sentence(text)
        text.to_s.split(/(?<=\.)\s/).first.to_s
      end

      def verb_help(program, name, spec, ask: false)
        out = ["#{name} — #{spec[:summary]}", ""]
        out << "dispatches #{spec[:verb]}" if spec[:kind] == :command
        out << "reads #{spec[:verb]}"      if spec[:kind] == :query
        out << "issued by #{spec[:role]}"  if spec[:role]
        out << ""
        invocation = ask ? "#{program} ask #{name}" : "#{program} #{name}"
        out << "  #{invocation}#{spec[:arguments].map { |a| " #{a[:path]}=…" }.join}"
        out << ""

        unless spec[:arguments].empty?
          width = spec[:arguments].map { |a| a[:path].length }.max
          spec[:arguments].each do |argument|
            notes = []
            notes << argument[:type]
            notes << "one of #{argument[:enum].join(', ')}" if argument[:enum]
            notes << "matches #{argument[:pattern]}"        if argument[:pattern]
            notes << "defaults to #{argument[:default].inspect}" unless argument[:default].nil?
            notes << argument[:note]                        if argument[:note]
            notes << "optional"                             unless argument[:required]
            out << "  #{argument[:path].ljust(width)}  #{notes.join('; ')}"
          end
          out << ""
        end

        unless Array(spec[:refusals]).empty?
          out << "refused when:"
          spec[:refusals].each { |refusal| out << "  #{refusal}" }
          out << ""
        end

        out.join("\n")
      end
    end
  end
end
