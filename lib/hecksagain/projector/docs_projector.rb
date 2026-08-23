require_relative "../naming"

module Hecksagain
  module Projector
    # A BLUEBOOK, PROJECTED AS ITS OWN USAGE DOCUMENTATION.
    #
    # WHAT THIS IS FOR. A chapter in this corpus already contains everything a
    # user of it needs: what each aggregate is (`description`), what each verb
    # is for (`goal`) and who issues it (`role`), which states it moves
    # between, what it refuses and in whose words (`given`, `invariant`,
    # `ensures`), and what each list is worth reading (`description` on a
    # query). None of that reaches the person who has to CALL the domain.
    # They read the source, or they read a document somebody wrote beside the
    # source and stopped updating.
    #
    # `docs/implemented/reference/` is the precedent and the contrast. `bin/reference`
    # generates it from the language's own Syntax chapter, so the reference
    # for the DSL cannot drift from the DSL. This is the same trick one level
    # down: the usage document for a DOMAIN, generated from that domain, so it
    # cannot drift from the domain either.
    #
    # WHY IT IS A PROJECTION AND NOT A GENERATOR SCRIPT. `Projector` is the
    # repository's registry of "canonical IR in, external artifact out" (§30
    # of the implementation plan), and this is exactly that shape: one
    # bluebook's IR in, markdown out, no runtime needed and no store touched.
    # Registered as `:docs` beside `:ir`, and reachable the way every
    # projector is — `Projector.call(:docs, bluebook: ...)`.
    #
    # AND AS A METHOD, which is the half that makes it get used.
    # `Facade::Surface` already installs a module per chapter carrying
    # `vision` and `aggregates`; `docs` joins them, so a booted domain answers
    # `QualityControl.docs` and an aggregate door answers
    # `QualityControl::Bug.docs`. A document you have to remember a script for
    # is a document nobody reads.
    #
    # WHAT IT DELIBERATELY DOES NOT DO: invent. Every sentence below comes out
    # of the chapter. Where a chapter says nothing — an aggregate with no
    # `description`, a command with no `goal` — the document says nothing
    # rather than filling the gap with a restatement of the name, because a
    # generated paragraph that only rephrases an identifier teaches a reader
    # to skim the ones that do not.
    module DocsProjector
      module_function

      # `options[:heading]` sets the top heading level (default 1), so a
      # caller splicing this into a larger document can push it down.
      def call(bluebook:, options: {})
        depth = (options[:heading] || 1).to_i
        only  = options[:aggregate]

        out = []
        out << chapter_header(bluebook, depth) unless only
        Array(aggregates(bluebook, only)).each { |aggregate| out << aggregate_section(aggregate, only ? depth : depth + 1) }
        out << closing(bluebook, depth + 1) unless only
        out.compact.join("\n").rstrip + "\n"
      end

      # A NAME THAT NAMES NOTHING IS REFUSED, not answered with an empty
      # document. Shipped the other way first: `options[:aggregate]` that
      # matched no head returned "" and exit 0, which is the silent-wrong-
      # answer shape this repository has already been bitten by twice in the
      # query engine. A misspelling should cost a sentence, not a puzzle.
      def aggregates(bluebook, only)
        return bluebook.aggregates unless only

        bluebook.aggregates.find { |aggregate| aggregate.hecks_name == only.to_s } ||
          raise(Runtime::NotFound,
                "#{bluebook.name} declares no aggregate named #{only.to_s.inspect} — " \
                "it declares #{bluebook.aggregates.map(&:hecks_name).sort.join(', ')}")
      end

      def h(depth, text) = "#{'#' * depth} #{text}"

      # ── the chapter ───────────────────────────────────────────────────

      def chapter_header(bluebook, depth)
        out = [h(depth, bluebook.name), ""]
        # THE VISION FIRST AND AS A QUOTE. It is the one sentence in a chapter
        # written for somebody who does not know the domain yet.
        out += ["> #{bluebook.vision}", ""] if bluebook.vision
        out << "#{bluebook.classification.to_s.capitalize} domain." if bluebook.classification
        out << "Previously known as `#{bluebook.formerly_known_as}`." if bluebook.formerly_known_as
        out << ""
        out << "Aggregates: #{bluebook.aggregates.map { |a| "[#{a.hecks_name}](##{anchor(a.hecks_name)})" }.join(', ')}."
        out << ""
        out.join("\n")
      end

      def anchor(name) = Naming.snake(name).tr("_", "-")

      # WHAT HAPPENS WITHOUT ANYBODY ASKING — the part of a domain a caller
      # cannot discover from any verb list, and the part most likely to surprise
      # them. A policy means one dispatch causes another, sometimes into a
      # different domain entirely; a saga means a sequence is being driven on
      # their behalf and can end in more than one place.
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
          out << "States: #{Array(shape[:states]).map { |s| "`#{s}`" }.join(' → ')}."
          out << ""
        end

        out.empty? ? nil : out.join("\n")
      end

      # ── one aggregate ─────────────────────────────────────────────────

      def aggregate_section(aggregate, depth)
        out = [h(depth, aggregate.hecks_name), ""]
        out += [aggregate.description, ""] if aggregate.description

        out << "Identified by `#{aggregate.identity_heads.join('`, `')}`." unless aggregate.identity_heads.empty?
        refs = aggregate.attributes.select(&:reference?)
        out << "References #{refs.map { |r| "`#{r.type.target_name}`" }.join(', ')}." unless refs.empty?
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
        # THE THING A CALLER GETS WRONG FIRST. An entity has no door of its
        # own: its verb is spelled through the aggregate that holds it, and
        # the parent's id travels alongside the entity's own identity.
        out << "Addressed through its holder — `#{aggregate.hecks_name}.#{entity.hecks_name}.<Verb>`, " \
               "passing the #{aggregate.hecks_name}'s `id` and this element's " \
               "`#{entity.identity_heads.join('`, `')}`."
        out << ""
        out << attributes_table(entity)
        out << lifecycle_section(entity, depth + 1)
        out << verbs_section(entity, depth + 1)
        out << queries_section(entity.queries, depth + 1, "Questions you can ask")
        out.compact.join("\n")
      end

      # ── the shape ─────────────────────────────────────────────────────

      def attributes_table(holder)
        attributes = holder.attributes.reject(&:reference?)
        return nil if attributes.empty?

        rows = attributes.map do |attribute|
          ["`#{attribute.name}`", shape_of(attribute, holder), rules_of(attribute, holder)]
        end
        table(%w[attribute shape rules], rows)
      end

      # A VALUE OBJECT'S FIELDS, NOT ITS NAME. `commit` typed `CommitRef` tells
      # a caller nothing; `{ value: String }` tells them what to send, which is
      # the single most common thing to get wrong at this boundary — a bare
      # scalar where an object is wanted.
      def shape_of(attribute, holder)
        value_object = value_object_for(attribute, holder)
        inner =
          if value_object
            "{ " + value_object.attributes.map { |f| "#{f.name}: #{f.type}" }.join(", ") + " }"
          else
            attribute.type.to_s
          end
        shape = attribute.list? ? "list of #{inner}" : inner
        attribute.optional? ? "#{shape} *(optional)*" : shape
      end

      def rules_of(attribute, holder)
        value_object = value_object_for(attribute, holder)
        rules = []
        rules << "one of #{closed_members(value_object).map { |m| "`#{m}`" }.join(', ')}" if closed_members(value_object).any?
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

      # An entity holds no value objects of its own — its argument types are
      # declared on the aggregate above it.
      def value_object_for(attribute, holder)
        scopes = [holder, holder.respond_to?(:hecks_owner) ? holder.hecks_owner : nil].compact
        scopes.each do |scope|
          next unless scope.respond_to?(:value_objects)

          found = scope.value_objects.find { |v| v.hecks_name == attribute.type.to_s }
          return found if found
        end
        nil
      end

      # ── the machine ───────────────────────────────────────────────────

      def lifecycle_section(holder, depth)
        lifecycle = holder.lifecycle or return nil

        rows = lifecycle.transitions.map do |name, transition|
          ["`#{name}`", "`#{Array(transition.from).join('`, `')}`", "`#{transition.target}`"]
        end
        [h(depth, "Lifecycle (`#{lifecycle.field}`)"), "",
         "Starts at `#{lifecycle.default}`. A verb not listed here can be issued from any state.", "",
         table(%w[verb from to], rows)].join("\n")
      end

      # ── the verbs ─────────────────────────────────────────────────────

      def verbs_section(holder, depth)
        commands = holder.commands
        return nil if commands.empty?

        out = [h(depth, "Verbs"), ""]
        commands.each { |command| out << command_entry(command, holder, depth + 1) }
        out.join("\n")
      end

      def command_entry(command, holder, depth)
        out = [h(depth, "#{command.hecks_name}#{command.creates? ? ' *(creates)*' : ''}"), ""]
        out += [command.goal, ""] if command.goal
        out << "Issued by: **#{command.role}**." if command.role
        out << ""

        arguments = command.attributes
        unless arguments.empty?
          rows = arguments.map do |attribute|
            shape = attribute.reference? ? "id of a `#{attribute.type.target_name}`" : shape_of(attribute, holder)
            ["`#{attribute.name}`", shape, attribute.optional? ? "" : "required"]
          end
          out << table(%w[argument shape needed], rows)
        end

        refusals = refusals_of(command, holder)
        unless refusals.empty?
          out << "Refused when:"
          out << ""
          refusals.each { |refusal| out << "- #{refusal}" }
          out << ""
        end

        out << "Guarantees: #{command.ensures.map(&:description).join('; ')}." unless command.ensures.empty?
        out << "Emits `#{command.emits.join('`, `')}`." unless command.emits.empty?
        out << ""
        out.join("\n")
      end

      # EVERY WAY THIS VERB CAN SAY NO, gathered from the three places a
      # chapter states them — the lifecycle it is an edge of, its own
      # `given`s, and the fact that a reference has to resolve. A caller
      # reading only the argument list learns none of these, and they are
      # most of what a domain is.
      def refusals_of(command, holder)
        refusals = []

        lifecycle = holder.lifecycle
        froms = lifecycle && lifecycle.transitions.filter_map do |name, transition|
          Array(transition.from) if name.to_s == command.hecks_name
        end.flatten.uniq
        refusals << "`#{lifecycle.field}` is anything other than #{froms.map { |f| "`#{f}`" }.join(' or ')}" if froms && !froms.empty?

        command.attributes.select(&:reference?).each do |reference|
          refusals << "no `#{reference.type.target_name}` exists for the id given as `#{reference.name}`"
        end

        refusals + command.givens.map { |given| "not: #{given.description}" }
      end

      # ── the reads ─────────────────────────────────────────────────────

      def queries_section(queries, depth, title)
        return nil if queries.empty?

        out = [h(depth, title), ""]
        queries.each do |query|
          shape   = query.to_h
          takes   = Array(shape[:attributes]).map { |a| "`#{a[:name]}`" }.join(", ")
          out << "**#{query.hecks_name}**#{takes.empty? ? '' : " (#{takes})"}  "
          out << (query.description ? "#{query.description}  " : "")
          filters = Array(shape[:wheres]).map { |w| "`#{w[:field]} #{w[:op]} #{w[:value].inspect}`" }
          out << "Filters: #{filters.join(', ')}." unless filters.empty?
          out << ""
        end
        out.join("\n")
      end

      def table(headers, rows)
        lines = ["| #{headers.join(' | ')} |", "|#{headers.map { '---' }.join('|')}|"]
        rows.each { |row| lines << "| #{row.join(' | ')} |" }
        (lines + [""]).join("\n")
      end
    end
  end
end
