module Hecks
  module Projector
    module DocsProjector
      # The sections of an aggregate or entity that say what can happen to it: lifecycle, verbs
      # and questions.
      module Behaviour
        module_function

        # The lifecycle table of `holder`, or `nil` when it has none.
        def lifecycle_section(holder, depth)
          lifecycle = holder.lifecycle or return nil

          rows = lifecycle.transitions.map do |name, transition|
            ["`#{name}`", "`#{Array(transition.from).join("`, `")}`", "`#{transition.target}`"]
          end
          [DocsProjector.h(depth, "Lifecycle (`#{lifecycle.field}`)"), "",
           "Starts at `#{lifecycle.default}`. A verb not listed here can be issued from any state.", "",
           DocsProjector.table(%w[verb from to], rows)].join("\n")
        end

        # The verbs of `holder`, one entry per command, or `nil` when it has none.
        def verbs_section(holder, depth)
          commands = holder.commands
          return nil if commands.empty?

          out = [DocsProjector.h(depth, "Verbs"), ""]
          commands.each { |command| out << command_entry(command, holder, depth + 1) }
          out.join("\n")
        end

        # One command: its goal, role, arguments, refusals, guarantees and events.
        def command_entry(command, holder, depth)
          [*command_opening(command, depth), *argument_lines(command, holder),
           *refusal_lines(refusals_of(command, holder)), *outcome_lines(command), ""].join("\n")
        end

        # The heading of a command entry, its goal and who issues it.
        def command_opening(command, depth)
          out = [DocsProjector.h(depth, "#{command.hecks_name}#{" *(creates)*" if command.creates?}"), ""]
          out += [command.goal, ""] if command.goal
          out << "Issued by: **#{command.role}**." if command.role
          out << ""
        end

        # The argument table of a command, or no lines when it takes none.
        def argument_lines(command, holder)
          arguments = command.attributes
          return [] if arguments.empty?

          [DocsProjector.table(%w[argument shape needed], command_argument_rows(arguments, holder))]
        end

        # The "Refused when" list, or no lines when nothing refuses the command.
        def refusal_lines(refusals)
          return [] if refusals.empty?

          ["Refused when:", "", *refusals.map { |refusal| "- #{refusal}" }, ""]
        end

        # What the command guarantees and emits, each only when it has any.
        def outcome_lines(command)
          out = []
          out << "Guarantees: #{command.ensures.map(&:description).join("; ")}." unless command.ensures.empty?
          out << "Emits `#{command.emits.join("`, `")}`." unless command.emits.empty?
          out
        end

        def command_argument_rows(arguments, holder)
          arguments.map do |attribute|
            shape = attribute.reference? ? "id of a `#{attribute.type.target_name}`" : Attributes.shape_of(attribute, holder)
            ["`#{attribute.name}`", shape, attribute.optional? ? "" : "required"]
          end
        end

        # Refusals come from the lifecycle edge, the command's `given`s and reference resolution.
        def refusals_of(command, holder)
          lifecycle_refusals(command, holder.lifecycle) + reference_refusals(command) +
            command.givens.map { |given| "not: #{given.description}" }
        end

        # The refusal for a command issued from a state its lifecycle does not allow.
        def lifecycle_refusals(command, lifecycle)
          return [] unless lifecycle

          froms = lifecycle.transitions.filter_map do |name, transition|
            Array(transition.from) if name.to_s == command.hecks_name
          end.flatten.uniq
          return [] if froms.empty?

          ["`#{lifecycle.field}` is anything other than #{froms.map { |f| "`#{f}`" }.join(" or ")}"]
        end

        # The refusal for each referenced record that may not exist.
        def reference_refusals(command)
          command.attributes.select(&:reference?).map do |reference|
            "no `#{reference.type.target_name}` exists for the id given as `#{reference.name}`"
          end
        end

        # The questions of an aggregate or entity, or `nil` when it has none.
        def queries_section(queries, depth, title)
          return nil if queries.empty?

          out = [DocsProjector.h(depth, title), ""]
          queries.each { |query| out.concat(query_lines(query)) }
          out.join("\n")
        end

        # One question: its name and parameters, description and filters.
        def query_lines(query)
          shape   = query.to_h
          takes   = Array(shape[:attributes]).map { |a| "`#{a[:name]}`" }.join(", ")
          out = ["**#{query.hecks_name}**#{" (#{takes})" unless takes.empty?}  ",
                 (query.description ? "#{query.description}  " : "")]
          out.concat(filter_lines(shape))
          out << ""
        end

        # The "Filters" line of a question, or no line when it filters on nothing.
        def filter_lines(shape)
          filters = Array(shape[:wheres]).map { |w| "`#{w[:field]} #{w[:op]} #{w[:value].inspect}`" }
          filters.empty? ? [] : ["Filters: #{filters.join(", ")}."]
        end
      end
    end
  end
end
