require_relative "../naming"

module Hecks
  module Projector
    # Projects a bluebook as its own usage documentation, in Markdown.
    # Reach it as `Projector.call(:docs, bluebook: ...)` or `Domain.docs`.
    module DocsProjector
      module_function

      # Projects `bluebook` as Markdown usage documentation.
      #
      # @param bluebook [Bluebook::Behaviour::Chapter] the chapter to document
      # @param options [Hash] optional inputs
      # @option options [Integer, String] :heading the top heading level; defaults to 1
      # @option options [String, Symbol, nil] :aggregate narrows the document to one
      #   aggregate, omitting the chapter header and closing sections
      # @return [String] the document, ending in a newline
      # @raise [Runtime::NotFound] if `options[:aggregate]` names no declared aggregate
      def call(bluebook:, options: {})
        depth = (options[:heading] || 1).to_i
        only  = options[:aggregate]

        out = []
        out << chapter_header(bluebook, depth) unless only
        Array(aggregates(bluebook, only)).each { |aggregate| out << aggregate_section(aggregate, only ? depth : depth + 1) }
        out << closing(bluebook, depth + 1) unless only
        "#{out.compact.join("\n").rstrip}\n"
      end

      # An unknown aggregate name is refused rather than answered with an empty document.
      def aggregates(bluebook, only)
        return bluebook.aggregates unless only

        bluebook.aggregates.find { |aggregate| aggregate.hecks_name == only.to_s } ||
          raise(Runtime::NotFound,
                "#{bluebook.name} declares no aggregate named #{only.to_s.inspect} — " \
                "it declares #{bluebook.aggregates.map(&:hecks_name).sort.join(", ")}")
      end

      def h(depth, text) = "#{"#" * depth} #{text}"

      def chapter_header(bluebook, depth)
        out = [h(depth, bluebook.name), ""]
        out += ["> #{bluebook.vision}", ""] if bluebook.vision
        out << "#{bluebook.classification.to_s.capitalize} domain." if bluebook.classification
        out << "Previously known as `#{bluebook.formerly_known_as}`." if bluebook.formerly_known_as
        out << ""
        out << "Aggregates: #{bluebook.aggregates.map { |a| "[#{a.hecks_name}](##{anchor(a.hecks_name)})" }.join(", ")}."
        out << ""
        out.join("\n")
      end

      def anchor(name) = Naming.snake(name).tr("_", "-")

      def closing(bluebook, depth)
        out = []

        unless bluebook.policies.empty?
          out << h(depth, "Reactions")
          out << ""
          out << "These fire on their own. Issuing the verb on the left also causes the one on the right."
          out << ""
          rows = bluebook.policies.map do |policy|
            ["`#{policy.on_event}`", "`#{policy.trigger_command}`", policy.target_domain || bluebook.name]
          end
          out << table(%w[on\ event dispatches in], rows)
        end

        bluebook.process_managers.each do |saga|
          shape = saga.to_h
          out << h(depth, "#{shape[:name]} (a saga)")
          out << ""
          out << "Starts on `#{shape[:starts_on]}`, ends on `#{shape[:ends_on]}`, " \
                 "correlated by `#{shape[:correlates_by]}`."
          out << ""
          out << "States: #{Array(shape[:states]).map { |s| "`#{s}`" }.join(" → ")}."
          out << ""
        end

        out.empty? ? nil : out.join("\n")
      end

      def aggregate_section(aggregate, depth)
        out = [h(depth, aggregate.hecks_name), ""]
        out += [aggregate.description, ""] if aggregate.description

        out << "Identified by `#{aggregate.identity_heads.join("`, `")}`." unless aggregate.identity_heads.empty?
        refs = aggregate.attributes.select(&:reference?)
        out << "References #{refs.map { |r| "`#{r.type.target_name}`" }.join(", ")}." unless refs.empty?
        out << ""

        out << attributes_table(aggregate)
        out << lifecycle_section(aggregate, depth + 1)
        out << verbs_section(aggregate, depth + 1)
        out << queries_section(aggregate.queries, depth + 1, "Questions you can ask")

        aggregate.entities.each { |entity| out << entity_section(aggregate, entity, depth + 1) }

        out.compact.join("\n")
      end

      def entity_section(aggregate, entity, depth)
        out = [h(depth, "#{entity.hecks_name} (within #{aggregate.hecks_name})"), ""]
        out += [entity.description, ""] if entity.description
        # An entity has no door of its own; its verbs go through the holding aggregate.
        out << "Addressed through its holder — `#{aggregate.hecks_name}.#{entity.hecks_name}.<Verb>`, " \
               "passing the #{aggregate.hecks_name}'s `id` and this element's " \
               "`#{entity.identity_heads.join("`, `")}`."
        out << ""
        out << attributes_table(entity)
        out << lifecycle_section(entity, depth + 1)
        out << verbs_section(entity, depth + 1)
        out << queries_section(entity.queries, depth + 1, "Questions you can ask")
        out.compact.join("\n")
      end

      def attributes_table(holder)
        attributes = holder.attributes.reject(&:reference?)
        return nil if attributes.empty?

        rows = attributes.map do |attribute|
          ["`#{attribute.name}`", shape_of(attribute, holder), rules_of(attribute, holder)]
        end
        table(%w[attribute shape rules], rows)
      end

      # A value object's fields, not its name: callers need to know what shape to send.
      def shape_of(attribute, holder)
        value_object = value_object_for(attribute, holder)
        inner =
          if value_object
            "{ #{value_object.attributes.map { |f| "#{f.name}: #{f.type}" }.join(", ")} }"
          else
            attribute.type.to_s
          end
        shape = attribute.list? ? "list of #{inner}" : inner
        attribute.optional? ? "#{shape} *(optional)*" : shape
      end

      def rules_of(attribute, holder)
        value_object = value_object_for(attribute, holder)
        rules = []
        rules << "one of #{closed_members(value_object).map { |m| "`#{m}`" }.join(", ")}" if closed_members(value_object).any?
        Array(value_object&.attributes).each do |field|
          rules << "`#{field.name}` matches `#{field.pattern}`" if field.pattern
          rules << "`#{field.name}` defaults to `#{field.default.inspect}`" unless field.default.nil?
        end
        rules += Array(value_object&.invariants).map(&:description)
        rules << "defaults to `#{attribute.default.inspect}`" unless attribute.default.nil?
        rules.empty? ? "" : rules.join("; ")
      end

      def closed_members(value_object)
        return [] unless value_object&.closed_set?

        value_object.members.flat_map(&:values).uniq
      end

      # An entity holds no value objects; its types are declared on the owning aggregate.
      def value_object_for(attribute, holder)
        scopes = [holder, holder.respond_to?(:hecks_owner) ? holder.hecks_owner : nil].compact
        scopes.each do |scope|
          next unless scope.respond_to?(:value_objects)

          found = scope.value_objects.find { |v| v.hecks_name == attribute.type.to_s }
          return found if found
        end
        nil
      end

      def lifecycle_section(holder, depth)
        lifecycle = holder.lifecycle or return nil

        rows = lifecycle.transitions.map do |name, transition|
          ["`#{name}`", "`#{Array(transition.from).join("`, `")}`", "`#{transition.target}`"]
        end
        [h(depth, "Lifecycle (`#{lifecycle.field}`)"), "",
         "Starts at `#{lifecycle.default}`. A verb not listed here can be issued from any state.", "",
         table(%w[verb from to], rows)].join("\n")
      end

      def verbs_section(holder, depth)
        commands = holder.commands
        return nil if commands.empty?

        out = [h(depth, "Verbs"), ""]
        commands.each { |command| out << command_entry(command, holder, depth + 1) }
        out.join("\n")
      end

      def command_entry(command, holder, depth)
        out = [h(depth, "#{command.hecks_name}#{" *(creates)*" if command.creates?}"), ""]
        out += [command.goal, ""] if command.goal
        out << "Issued by: **#{command.role}**." if command.role
        out << ""

        arguments = command.attributes
        out << table(%w[argument shape needed], command_argument_rows(arguments, holder)) unless arguments.empty?

        refusals = refusals_of(command, holder)
        unless refusals.empty?
          out << "Refused when:"
          out << ""
          refusals.each { |refusal| out << "- #{refusal}" }
          out << ""
        end

        out << "Guarantees: #{command.ensures.map(&:description).join("; ")}." unless command.ensures.empty?
        out << "Emits `#{command.emits.join("`, `")}`." unless command.emits.empty?
        out << ""
        out.join("\n")
      end

      def command_argument_rows(arguments, holder)
        arguments.map do |attribute|
          shape = attribute.reference? ? "id of a `#{attribute.type.target_name}`" : shape_of(attribute, holder)
          ["`#{attribute.name}`", shape, attribute.optional? ? "" : "required"]
        end
      end

      # Refusals come from the lifecycle edge, the command's `given`s and reference resolution.
      def refusals_of(command, holder)
        refusals = []

        lifecycle = holder.lifecycle
        froms = lifecycle && lifecycle.transitions.filter_map do |name, transition|
          Array(transition.from) if name.to_s == command.hecks_name
        end.flatten.uniq
        if froms && !froms.empty?
          refusals << "`#{lifecycle.field}` is anything other than #{froms.map do |f|
            "`#{f}`"
          end.join(" or ")}"
        end

        command.attributes.select(&:reference?).each do |reference|
          refusals << "no `#{reference.type.target_name}` exists for the id given as `#{reference.name}`"
        end

        refusals + command.givens.map { |given| "not: #{given.description}" }
      end

      def queries_section(queries, depth, title)
        return nil if queries.empty?

        out = [h(depth, title), ""]
        queries.each do |query|
          shape   = query.to_h
          takes   = Array(shape[:attributes]).map { |a| "`#{a[:name]}`" }.join(", ")
          out << "**#{query.hecks_name}**#{" (#{takes})" unless takes.empty?}  "
          out << (query.description ? "#{query.description}  " : "")
          filters = Array(shape[:wheres]).map { |w| "`#{w[:field]} #{w[:op]} #{w[:value].inspect}`" }
          out << "Filters: #{filters.join(", ")}." unless filters.empty?
          out << ""
        end
        out.join("\n")
      end

      def table(headers, rows)
        lines = ["| #{headers.join(" | ")} |", "|#{headers.map { "---" }.join("|")}|"]
        rows.each { |row| lines << "| #{row.join(" | ")} |" }
        (lines + [""]).join("\n")
      end
    end
  end
end
