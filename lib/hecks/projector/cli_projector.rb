require_relative "../naming"

module Hecks
  module Projector
    # A bluebook, projected as its own command-line surface.
    #
    # Every verb a domain declares is a subcommand; every argument is an
    # option whose type, whose admitted values and whose required-ness are
    # already stated in the chapter. A hand-written CLI restates all of it and
    # then drifts — and the first thing to drift is the help text, which is the
    # only part anybody reads.
    #
    # ## What is projected
    #
    # This answers the surface only — the verb tree, the argument spec, the
    # usage text — and nothing executes here. One small generic runner
    # (`bin/run`) boots a domain, asks for this, parses against it and
    # dispatches.
    #
    # ## Why project rather than generate
    #
    # The alternative was generating an executable per domain, which is what
    # `bin/project_rust` does for a whole runtime and would be the more
    # spectacular version of this. It was not taken: a generated program is a
    # second copy of the dispatch logic, and it needs regenerating on every
    # bluebook edit — a second tax beside the era gate, paid for a file nobody
    # reads. Projecting the surface keeps one dispatcher and a help text that
    # cannot be stale, because it is computed at the moment it is printed.
    #
    # ## The typing is the point
    #
    # A CLI hands everything over as a String. `sequence.value=99` has to
    # become the Integer 99 or the runtime refuses it, and the only honest
    # place to learn that is the value object's own declared field type. A CLI
    # that guessed — "it looks like a number" — would send 99 for a version
    # string of "99" and be wrong in a way nobody could see.
    module CliProjector
      module_function

      # Two namespaces, not one — `{ verbs:, questions:, usage: }`.
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
      #
      # @param bluebook [Bluebook::Chapter] the booted domain to project
      # @param options [Hash{Symbol => Object}] `:program` (String, defaults to
      #   `"bin/run"`) is echoed into the usage text; `:verb` (String) and `:ask`
      #   (Boolean) select one verb's `--help` text instead of the full usage
      # @return [Hash{Symbol => Object}] `:verbs` and `:questions` map each projected
      #   name to its spec hash; `:names` maps `:command`/`:question` to an alias table
      #   (short and full spelling both keying the full name); `:usage` is the
      #   pre-rendered help text
      # @raise [Bluebook::DSL::Malformed] if two verbs project to the same command-line
      #   name
      def call(bluebook:, options: {})
        verbs     = {}
        questions = {}

        bluebook.aggregates.each do |aggregate|
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

          # A port is a verb too, and leaving it off the map was a real gap
          # rather than a tasteful omission. The runtime has always dispatched
          # a port operation by exactly the same name as a command — the
          # projection simply never listed one, so `run_specs` and `file`
          # answered "no such verb" while working perfectly through Ruby.
          #
          # It matters most for the caller with no other door. An agent that
          # may not shell out reaches this domain only through the projected
          # CLI, and a port it cannot see is a capability it does not have.
          aggregate.ports.each do |port|
            port.operations.each { |o| claim(verbs, name_for(aggregate, o), port_spec(bluebook, aggregate, port, o)) }
          end
        end

        # A report is a question too, and leaving it off was the same gap the
        # ports had: `Dispatcher#query` has always answered `Domain.ReportName`,
        # the projection simply never listed one — so the composed reads worked
        # from Ruby and did not exist for anybody whose only door is the command
        # line.
        #
        # It matters most for exactly what a report is for. Every other question
        # here answers with rows and leaves the arithmetic to the reader; a
        # `group_by` report is the one that counts. An agent that cannot reach
        # it can list bugs all day and never answer "how are we doing".
        #
        # **One dot, not two** — a report belongs to the chapter rather than to any
        # aggregate (that is what rootless means), so it is addressed
        # `QualityControl.BugsByStatus` where a query is
        # `QualityControl::Bug.Queue`. `Dispatcher#query` splits on precisely
        # that difference.
        bluebook.read_models.each do |model|
          claim(questions, Naming.snake(model.hecks_name), report_spec(bluebook, model))
        end

        # The short spelling, where it cannot be ambiguous. `pizzas
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
      #
      # @param specs [Hash{String => Hash}] the verb or question map being projected,
      #   mutated in place: each spec hash gains a `:short` key
      # @return [void]
      def shorten(specs)
        tails = specs.keys.group_by { |name| name.split(".").last }
        specs.each do |name, spec|
          tail = name.split(".").last
          spec[:short] = tails[tail].length == 1 ? tail : name
        end
      end

      # Builds the alias table `CliRunner` resolves a typed name against.
      #
      # @param specs [Hash{String => Hash}] a verb or question map whose specs already
      #   carry `:short` (set by `shorten`)
      # @return [Hash{String => String}] every accepted spelling — the full name and
      #   its `:short` form — mapped to the full name
      def aliases(specs)
        specs.each_with_object({}) do |(name, spec), map|
          map[name]         = name
          map[spec[:short]] = name
        end
      end

      # A name is claimed once. A command and a query of one name are legal in
      # a chapter — the language namespaces them — and ambiguous as
      # subcommands. Refused here rather than silently resolving to whichever
      # was walked first, which is how `Ticket.Filed` (a command) and
      # `Ticket.Filed` (a query) sat undetected until something flattened them.
      #
      # @param verbs [Hash{String => Hash}] the verb or question map being built,
      #   mutated in place
      # @param name [String] the command-line name this spec claims
      # @param spec [Hash{Symbol => Object}] the spec hash to store under `name`
      # @return [void]
      # @raise [Bluebook::DSL::Malformed] if `name` is already claimed by another verb
      def claim(verbs, name, spec)
        if verbs.key?(name)
          raise Bluebook::DSL::Malformed,
                "two verbs project to the command-line name #{name.inspect}: " \
                "#{verbs[name][:verb]} and #{spec[:verb]} — rename one"
        end

        verbs[name] = spec
      end

      # Builds the dotted command-line name for one verb: `aggregate[.entity].verb`,
      # snake-cased.
      #
      # @param aggregate [Bluebook::Aggregate] the verb's owning aggregate
      # @param verb [Bluebook::Command, Bluebook::Query, Bluebook::PortOperation]
      #   the command, query or port operation being named
      # @param entity [Bluebook::Entity, nil] the entity the verb is declared on, or `nil`
      #   for an aggregate-level verb
      # @return [String] the dotted, snake-cased command-line name
      def name_for(aggregate, verb, entity = nil)
        parts = [Naming.snake(aggregate.hecks_name)]
        parts << Naming.snake(entity.hecks_name) if entity
        parts << Naming.snake(verb.hecks_name)
        parts.join(".")
      end

      # Builds the verb's fully-qualified language name, `Bluebook::Aggregate[.Entity].Verb`,
      # for display in help text.
      #
      # @param bluebook [Bluebook::Chapter] the verb's owning chapter
      # @param aggregate [Bluebook::Aggregate] the verb's owning aggregate
      # @param verb [Bluebook::Command, Bluebook::Query, Bluebook::PortOperation]
      #   the command, query or port operation being named
      # @param entity [Bluebook::Entity, nil] the entity the verb is declared on, or `nil`
      #   for an aggregate-level verb
      # @return [String] the fully-qualified name, as the language spells it
      def fqn(bluebook, aggregate, verb, entity = nil)
        [bluebook.name, "::", aggregate.hecks_name, ".",
         entity ? "#{entity.hecks_name}." : "", verb.hecks_name].join
      end

      # The arguments a receiver adds, before any verb-specific one. Shared by
      # `command_spec` and `port_spec` — a port operation always addresses an
      # aggregate record (`port_spec` passes `receiver: :aggregate`, never
      # `:entity` or `nil`, because a port is declared on an aggregate, never
      # an entity), and this is exactly the same "how do I name the record"
      # question a command with a receiver already answers, so it is answered
      # once, here, rather than duplicated.
      #
      # `nil` — a creating command — takes none: there is no existing record
      # yet for `to=` to name.
      #
      # @param receiver [Symbol, nil] `:entity`, `:aggregate`, or `nil` for a creating
      #   command that names no existing record
      # @param aggregate [Bluebook::Aggregate] the aggregate the record belongs to
      # @param entity [Bluebook::Entity, nil] the entity to name, required when
      #   `receiver` is `:entity`
      # @return [Array<Hash{Symbol => Object}>] the `to`/`to.aggregate`+`to.entity` option
      #   specs this receiver needs, or `[]` for `nil`
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

      # ── one verb ──────────────────────────────────────────────────────

      # Projects one command into the spec `verb_help` and `CliRunner` both read.
      #
      # @param bluebook [Bluebook::Chapter] the command's owning chapter
      # @param aggregate [Bluebook::Aggregate] the command's owning aggregate
      # @param entity [Bluebook::Entity, nil] the entity the command is declared on, or
      #   `nil` for an aggregate-level command
      # @param command [Bluebook::Command] the command being projected
      # @return [Hash{Symbol => Object}] `:verb` (fully-qualified name), `:kind` (`:command`),
      #   `:summary`, `:role` (String, nil if the command declares none), `:role_gated`
      #   (Boolean), `:creates` (Boolean), `:receiver` (`:entity`, `:aggregate` or `nil`),
      #   `:legacy_receiver` (`:id` or `nil`), `:legacy_arguments`, `:refusals`
      #   (see `refusals`) and `:arguments` (see `options_for`)
      def command_spec(bluebook, aggregate, entity, command)
        holder    = entity || aggregate
        arguments = command.attributes.flat_map { |a| options_for(a, holder, aggregate) }
        receiver  = if entity
                      :entity
                    else
                      (command.creates? ? nil : :aggregate)
                    end

        # The receiver is not a command argument. An aggregate command names
        # its record through to; an entity command needs both the aggregate
        # record and the entity element within it. Keeping those paths in the
        # projected option list makes the human-facing request complete while
        # CommandRequest can remove them before it builds with: from the
        # command's declared facts.
        #
        # Existing aggregate scripts may still spell the receiver id=... .
        # That alias is deliberately hidden from help and recorded separately
        # as legacy_arguments; new help and examples teach only to=... .
        arguments = receiver_options(receiver, aggregate, entity) + arguments
        legacy_arguments = receiver == :aggregate ? [{ path: "id", type: "String", required: true }] : []

        { verb: fqn(bluebook, aggregate, command, entity), kind: :command,
          summary: command.goal, role: command.role, role_gated: !command.role.to_s.empty?,
          creates: command.creates?,
          receiver: receiver, legacy_receiver: (receiver == :aggregate ? :id : nil),
          legacy_arguments: legacy_arguments,
          refusals: refusals(command, holder), arguments: arguments }
      end

      # A port operation reads as a verb but reports as a boundary.
      #
      # `creates: false` because it makes no record, and `refusals: []`
      # because it has none in the sense every other verb means: a command's
      # refusals are sentences the chapter will say back to you, and an
      # outbound operation's failure is somebody else's sentence, unknowable
      # from here.
      #
      # The summary names both endings, which is the one thing a caller most
      # needs and cannot infer. `run_specs` looks like it either works or
      # errors; what it actually does is answer `SpecsCompleted` even when the
      # suite is red, and refuse only when rspec could not run. Somebody
      # reading `--help` should not have to open the hecksagon to find that
      # out.
      #
      # @param bluebook [Bluebook::Chapter] the port's owning chapter
      # @param aggregate [Bluebook::Aggregate] the aggregate the port is declared on
      # @param port [Bluebook::DomainPort] the port the operation is declared on
      # @param operation [Bluebook::PortOperation] the operation being projected
      # @return [Hash{Symbol => Object}] `:verb` (the `Aggregate.port.operation` name),
      #   `:kind` (`:command`), `:creates` (`false`), `:receiver` (`:aggregate`),
      #   `:refusals` (`[]`), `:role` (String, who calls whom through the port),
      #   `:role_gated` (`false`), `:summary` (see `port_summary`) and `:arguments`
      #   (see `options_for`)
      def port_spec(bluebook, aggregate, port, operation)
        arguments = receiver_options(:aggregate, aggregate, nil) +
                    operation.attributes.flat_map { |a| options_for(a, aggregate, aggregate) }

        # The wire name carries the port, the typed name does not.
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
          # `role:` here is descriptive text, not an authorization gate —
          # who calls whom through the port, for `--help`/`verb_help`'s
          # "issued by" line. A port operation never reaches
          # `CommandRules::Authorization#refuse_role_mismatch` (only
          # `CommandInterpreter`/`EntityInterpreter` call it, never the port
          # dispatch path), so `role_gated: false` always, unlike
          # `command_spec` where the same key name means a real one.
          role: if operation.outbound?
                  "#{aggregate.hecks_name} asking #{port.name}"
                else
                  "#{port.name} telling #{aggregate.hecks_name}"
                end,
          role_gated: false,
          summary: port_summary(port, operation), arguments: arguments }
      end

      # Names both endings a port operation can have: what an inbound `tells` records,
      # or what an outbound `asks` came back with and what it said instead.
      #
      # @param port [Bluebook::DomainPort] the operation's owning port
      # @param operation [Bluebook::PortOperation] the operation being summarized
      # @return [String] one line, worded for `--help`
      def port_summary(port, operation)
        return "#{port.name} reports it; emits #{operation.emits.join(', ')}" unless operation.outbound?

        "Ask #{port.name} — answers #{operation.answers}, refuses #{operation.refuses}"
      end

      # A rootless report takes nothing; a rooted one takes the id of the
      # record it is a view of, under the name the model gave that reference.
      #
      # @param bluebook [Bluebook::Chapter] the report's owning chapter
      # @param model [Bluebook::ReadModel] the report being projected
      # @return [Hash{Symbol => Object}] `:verb` (`Chapter.ReportName`), `:kind`
      #   (`:query`), `:summary` and `:arguments` (`[]`, or one required id option
      #   named after the model's `reference_name` when it declares a `reference_target`)
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

      # Projects one query into the spec `verb_help` and `CliRunner` both read.
      #
      # @param bluebook [Bluebook::Chapter] the query's owning chapter
      # @param aggregate [Bluebook::Aggregate] the query's owning aggregate
      # @param entity [Bluebook::Entity, nil] the entity the query is declared on, or
      #   `nil` for an aggregate-level query
      # @param query [Bluebook::Query] the query being projected
      # @return [Hash{Symbol => Object}] `:verb` (fully-qualified name), `:kind`
      #   (`:query`), `:summary` and `:arguments` (see `options_for`)
      def query_spec(bluebook, aggregate, entity, query)
        arguments = Array(query.to_h[:attributes]).flat_map do |declared|
          attribute = query.attributes.find { |a| a.name.to_s == declared[:name].to_s }
          attribute ? options_for(attribute, entity || aggregate, aggregate) : []
        end

        { verb: fqn(bluebook, aggregate, query, entity), kind: :query,
          summary: query.description, arguments: arguments }
      end

      # ── one argument, flattened ───────────────────────────────────────

      # A value object becomes one option per field, dotted. `commit` typed
      # `CommitRef` is `--commit.value`, because that is the shape the runtime
      # wants and a flat `--commit` would have to guess which field it meant.
      # Single-field value objects — almost all of them — read fine either way,
      # and the runner accepts the short form for exactly those.
      # Recursive, and it has to be. A value object may hold another one —
      # pizzas' `Pizza` holds a `Price` and a `Size` — so stopping after one
      # level produced `pizza.price_cents=1500` and sent the string "1500"
      # where `{ cents: 1500 }` belonged.
      #
      # The runtime took it. `qa/FINDINGS.md` #2 is exactly that gap —
      # `Value::Coercion.build` does not validate nested value objects — so a
      # one-level CLI is not merely inconvenient, it is a machine for writing
      # malformed records into a real store, which is what it did on its first
      # run against the pizzas database.
      #
      # @param attribute [Bluebook::Attribute] the field being projected
      # @param holder [Bluebook::Aggregate, Bluebook::Entity, Class] the construct
      #   `attribute` is declared on; a `Bluebook::ValueObject` subclass on a recursive call
      # @param aggregate [Bluebook::Aggregate] the top-level aggregate, kept across recursion
      #   so a nested value object can still be found
      # @param prefix [String, nil] the dotted path built so far, `nil` at the top level
      # @param optional [Boolean, nil] whether an enclosing field already makes this one
      #   optional; `nil` defers to `attribute.optional?`
      # @return [Array<Hash{Symbol => Object}>] one option spec per leaf field, each with
      #   `:path`, `:type`, `:required`, and optionally `:note`, `:enum`, `:pattern`,
      #   `:default`, `:list`
      def options_for(attribute, holder, aggregate, prefix = nil, optional = nil)
        path = [prefix, attribute.name].compact.join(".")
        optional ||= attribute.optional?
        return [reference_option(attribute)] if attribute.reference?

        value_object = value_object_for(attribute, holder, aggregate)
        return [scalar_option(path, attribute, optional)] unless value_object

        # A list says so, all the way down to its leaves.
        #
        # Without this a `list_of(Tag)` projected exactly like a single Tag:
        # one option, `tags.value`, indistinguishable from a scalar. So the
        # help said to pass one, `CliDoor#bury` overwrote the leaf each time,
        # and passing two tags stored the second and lost the first without
        # saying anything. A missing argument is refused loudly; a forgotten
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

      # Projects a `reference_to` attribute as the id of the record it points at.
      #
      # @param attribute [Bluebook::Attribute] a `reference?` attribute
      # @return [Hash{Symbol => Object}] `:path`, `:type` (`"String"`), `:required` and
      #   `:note`
      def reference_option(attribute)
        { path: attribute.name.to_s, type: "String", required: !attribute.optional?,
          note: "id of a #{attribute.type.target_name}" }
      end

      # Projects one leaf field — a plain attribute, or one field of a flattened
      # value object.
      #
      # @param path [String] the dotted option path this field is reached at
      # @param field [Bluebook::Attribute] the field being projected
      # @param optional [Boolean] whether this option may be omitted
      # @param enum [Array<Object>] the closed set of values this field admits, `[]` for
      #   an open field
      # @return [Hash{Symbol => Object}] `:path`, `:type`, `:required`, plus `:enum` when
      #   `enum` is non-empty, `:pattern` when `field` declares one, and `:default` when
      #   `field` declares a non-nil one
      def scalar_option(path, field, optional, enum: [])
        option = { path: path, type: field.type.to_s, required: !optional }
        option[:enum]    = enum          unless enum.empty?
        option[:pattern] = field.pattern if field.respond_to?(:pattern) && field.pattern
        option[:default] = field.default if field.respond_to?(:default) && !field.default.nil?
        option
      end

      # The values a `one_of` value object's field is closed to, for the option's
      # `:enum`.
      #
      # @param value_object [Class] a `Bluebook::ValueObject` subclass
      # @param field [Bluebook::Attribute] the value object's field being projected
      # @return [Array<Object>] the distinct values every declared member gives this
      #   field, or `[]` when the value object declares no closed set
      def closed_members(value_object, field)
        return [] unless value_object.closed_set?

        value_object.members.filter_map { |member| member[field.name] }.uniq
      end

      # Finds the value object type an attribute declares, if any — the fork between
      # `scalar_option` (one option) and recursing into `options_for` (one option per
      # field).
      #
      # @param attribute [Bluebook::Attribute] the field whose type is being resolved
      # @param holder [Bluebook::Aggregate, Bluebook::Entity, Class, nil] the construct
      #   `attribute` is declared on, searched first
      # @param aggregate [Bluebook::Aggregate, nil] the top-level aggregate, searched when
      #   `holder` does not declare the value object itself
      # @return [Class, nil] the matching `Bluebook::ValueObject` subclass, or `nil` if
      #   `attribute`'s type names no value object in scope
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
      #
      # @param command [Bluebook::Command] the command whose refusals are being projected
      # @param holder [Bluebook::Aggregate, Bluebook::Entity] the aggregate or entity the
      #   command's lifecycle guard, if any, is checked against
      # @return [Array<String>] one sentence per way the command can refuse: a lifecycle
      #   state mismatch, a missing referenced record per `reference_to` attribute, and
      #   each declared `given`'s description, in that order
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

      # Renders the full verb/question table, or one verb's `--help` text when
      # `options[:verb]` names one.
      #
      # @param bluebook [Bluebook::Chapter] the projected chapter, for its name and vision
      #   line
      # @param verbs [Hash{String => Hash}] the projected, `shorten`ed command map
      # @param questions [Hash{String => Hash}] the projected, `shorten`ed query map
      # @param options [Hash{Symbol => Object}] `:program` (String), `:verb` (String, nil)
      #   and `:ask` (Boolean) — see `call`
      # @return [String] the rendered help text
      def usage(bluebook, verbs, questions, options)
        program = options[:program] || "bin/run"
        only    = options[:verb]

        # Which namespace, when both hold the name. `options[:ask]` says so;
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

      # Picks one verb whose full spelling differs from its short one, to show the
      # caller both forms exist.
      #
      # @param verbs [Hash{String => Hash}] the projected, `shorten`ed command map
      # @return [String] `"<short> is also <full>"`, or `""` if every verb's short form
      #   is its full name (a one-aggregate domain, where no name ever collides)
      def example_qualified(verbs)
        name, spec = verbs.find { |key, value| key != value[:short] } || verbs.first
        name ? "#{spec[:short]} is also #{name}" : ""
      end

      # A query's `description` is written as a paragraph — it argues for why
      # the list is worth reading. A verb table wants the first sentence of
      # that argument; `--help` still prints the whole thing.
      #
      # @param text [String, nil] the full description, or `nil`
      # @return [String] the text up to and including its first `.`, or `""` for `nil`
      def first_sentence(text)
        text.to_s.split(/(?<=\.)\s/).first.to_s
      end

      # Four text blocks, in fixed display order — meta (name/kind/role),
      # invocation, arguments, refusals. Each block is independent of the
      # others' content (only the output order is fixed, and stays fixed
      # below), so each is its own method returning the lines it
      # contributes — `[]` when it contributes none — concatenated in the
      # same order the original inline version built them in.
      #
      # @param program [String] how the caller was invoked, echoed in the invocation line
      # @param name [String] the verb's short display name
      # @param spec [Hash{Symbol => Object}] the verb or question's projected spec (see
      #   `command_spec`, `port_spec`, `report_spec` or `query_spec`)
      # @param ask [Boolean] whether this is a question, reached through `ask`
      # @return [String] the verb's full `--help` text
      def verb_help(program, name, spec, ask: false)
        out = verb_help_meta_lines(name, spec)
        out.concat(verb_help_invocation_lines(program, name, spec, ask))
        out.concat(verb_help_argument_lines(spec))
        out.concat(verb_help_refusal_lines(spec))
        out.join("\n")
      end

      # Renders the name/summary heading, plus the dispatched or read verb and issuing
      # role when the spec declares them.
      #
      # @param name [String] the verb's short display name
      # @param spec [Hash{Symbol => Object}] the verb or question's projected spec
      # @return [Array<String>] the meta block's lines
      def verb_help_meta_lines(name, spec)
        out = ["#{name} — #{spec[:summary]}", ""]
        out << "dispatches #{spec[:verb]}" if spec[:kind] == :command
        out << "reads #{spec[:verb]}"      if spec[:kind] == :query
        out << "issued by #{spec[:role]}"  if spec[:role]
        out
      end

      # Renders the one-line example invocation, with every argument's path as a
      # placeholder.
      #
      # @param program [String] how the caller was invoked
      # @param name [String] the verb's short display name
      # @param spec [Hash{Symbol => Object}] the verb or question's projected spec, read
      #   for `:arguments`
      # @param ask [Boolean] whether to show the `ask` form of the invocation
      # @return [Array<String>] the invocation block's lines
      def verb_help_invocation_lines(program, name, spec, ask)
        invocation = ask ? "#{program} ask #{name}" : "#{program} #{name}"
        ["", "  #{invocation}#{spec[:arguments].map { |a| " #{a[:path]}=…" }.join}", ""]
      end

      # Renders one line per declared argument: its type, admitted values, pattern,
      # default and whether it is optional.
      #
      # @param spec [Hash{Symbol => Object}] the verb or question's projected spec, read
      #   for `:arguments`
      # @return [Array<String>] the argument block's lines, `[]` if the verb takes none
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

      # Renders the "refused when:" block, one line per way the verb can say no.
      #
      # @param spec [Hash{Symbol => Object}] the verb or question's projected spec, read
      #   for `:refusals`
      # @return [Array<String>] the refusal block's lines, `[]` if the verb declares none
      def verb_help_refusal_lines(spec)
        return [] if Array(spec[:refusals]).empty?

        ["refused when:", *spec[:refusals].map { |refusal| "  #{refusal}" }, ""]
      end
    end
  end
end
