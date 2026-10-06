require_relative "docs_projector"
require_relative "../forms/field_shape"

module Hecks
  module Projector
    # A bluebook projected as prose an SME can read back and confirm.
    # Every sentence quotes a declared `description`, `goal` or `given`; nothing is invented.
    module NarrateProjector
      module_function

      # Projects `bluebook` as prose; `options[:heading]` sets the top heading level.
      #
      # @param bluebook [Bluebook::Behaviour::Chapter] the chapter to narrate
      # @param options [Hash] `:heading` (Integer, default 1) and `:aggregate` (narrows to one
      #   aggregate, omitting the chapter intro and reactions)
      # @return [String] Markdown prose ending in a newline
      # @raise [Runtime::NotFound] if `options[:aggregate]` names no declared aggregate
      def call(bluebook:, options: {})
        depth = (options[:heading] || 1).to_i
        only  = options[:aggregate]

        sections = []
        sections << chapter_intro(bluebook, depth) unless only
        Array(DocsProjector.aggregates(bluebook, only)).each do |aggregate|
          sections << aggregate_narrative(aggregate, only ? depth : depth + 1)
        end
        sections << reactions_narrative(bluebook, depth + 1) unless only
        "#{sections.compact.join("\n\n").rstrip}\n"
      end

      def chapter_intro(bluebook, depth)
        parts = [DocsProjector.h(depth, bluebook.name)]
        parts << bluebook.vision if bluebook.vision

        meta = []
        meta << "This is a #{bluebook.classification} domain." if bluebook.classification
        meta << "It was formerly known as `#{bluebook.formerly_known_as}`." if bluebook.formerly_known_as
        parts << meta.join(" ") unless meta.empty?

        names = bluebook.aggregates.map(&:hecks_name)
        parts << "It's told through #{to_sentence_list(names)}." unless names.empty?
        parts.join("\n\n")
      end

      def aggregate_narrative(aggregate, depth)
        parts = [DocsProjector.h(depth, aggregate.hecks_name)]
        parts << aggregate.description if aggregate.description
        parts << identity_sentence(aggregate)

        refs = aggregate.attributes.select(&:reference?)
        unless refs.empty?
          parts << "Each one is linked to #{to_sentence_list(refs.map do |r|
            "#{a_or_an(r.type.target_name)} #{r.type.target_name}"
          end)}."
        end

        parts << lifecycle_narrative(aggregate)
        parts << verbs_narrative(aggregate, depth + 1)
        parts << queries_narrative(aggregate.queries, aggregate.hecks_name, depth + 1)

        aggregate.entities.each { |entity| parts << entity_narrative(aggregate, entity, depth + 1) }
        parts.compact.join("\n\n")
      end

      def identity_sentence(holder)
        return nil if holder.identity_heads.empty?

        "Every #{holder.hecks_name} is identified by its #{to_sentence_list(holder.identity_heads.map { |h| "`#{h}`" })}."
      end

      def entity_narrative(aggregate, entity, depth)
        parts = [DocsProjector.h(depth, "#{entity.hecks_name} (within #{aggregate.hecks_name})")]
        parts << entity.description if entity.description
        parts << "Reached through its #{aggregate.hecks_name} — you address it by the #{aggregate.hecks_name}'s " \
                 "id together with its own `#{entity.identity_heads.join("`, `")}`."

        parts << lifecycle_narrative(entity)
        parts << verbs_narrative(entity, depth + 1)
        parts << queries_narrative(entity.queries, entity.hecks_name, depth + 1)
        parts.compact.join("\n\n")
      end

      def lifecycle_narrative(holder)
        lifecycle = holder.lifecycle or return nil

        sentences = ["It carries a `#{lifecycle.field}`, starting out at `#{lifecycle.default}`."]
        lifecycle.transitions.each do |name, transition|
          froms = Array(transition.from).map { |f| "`#{f}`" }
          sentences << "**#{name}** moves it from #{to_sentence_list(froms, conj: "or")} to `#{transition.target}`."
        end
        sentences << "A verb not listed here can be issued from any state."
        sentences.join(" ")
      end

      def verbs_narrative(holder, depth)
        return nil if holder.commands.empty?

        header = DocsProjector.h(depth, "What can happen to #{a_or_an(holder.hecks_name)} #{holder.hecks_name}")
        body   = holder.commands.map { |command| command_paragraph(command, holder) }.join("\n\n")
        "#{header}\n\n#{body}"
      end

      # Each sentence states one independent fact, so nil-or-string plus `compact.join` suffices.
      def command_paragraph(command, holder)
        [
          command_headline_sentence(command),
          command_role_sentence(command),
          command_creation_sentence(command, holder),
          command_arguments_sentence(command),
          command_references_sentence(command),
          command_conditions_sentence(command, holder),
          command_guarantees_sentence(command),
          command_emits_sentence(command)
        ].compact.join(" ")
      end

      # The goal is quoted exactly as declared, never recased to fit mid-sentence.
      def command_headline_sentence(command)
        "**#{command.hecks_name}**#{command.goal ? " — #{command.goal}." : "."}"
      end

      def command_role_sentence(command)
        return nil unless command.role

        "Issued by #{a_or_an(command.role)} #{command.role}."
      end

      # `acts_on.nil?`, not `creates?`: `creates?` is true for every entity verb, which would
      # wrongly say `LedgerEntry.Amend` creates a new ledger entry.
      def command_creation_sentence(command, holder)
        return nil unless command.acts_on.nil?

        "This is how a new #{holder.hecks_name} comes into being."
      end

      def command_arguments_sentence(command)
        arguments = command.attributes.reject(&:reference?)
        return nil if arguments.empty?

        "It takes #{to_sentence_list(arguments.map { |a| Forms::Humanize.label(a.name.to_s).downcase })}."
      end

      def command_references_sentence(command)
        refs = command.attributes.select(&:reference?)
        return nil if refs.empty?

        "It's aimed at one existing #{to_sentence_list(refs.map { |r| r.type.target_name })}, by id."
      end

      def command_conditions_sentence(command, holder)
        conditions = conditions_of(command, holder)
        return nil if conditions.empty?

        "It only goes through if #{conditions.join("; ")}."
      end

      def command_guarantees_sentence(command)
        guarantees = command.ensures.map(&:description)
        return nil if guarantees.empty?

        "When it succeeds: #{guarantees.join("; ")}."
      end

      def command_emits_sentence(command)
        return nil if command.emits.empty?

        "It records `#{command.emits.join("`, `")}` as a fact."
      end

      # Required conditions stated positively ("only goes through if X"), from the lifecycle
      # edge and the command's `given`s.
      def conditions_of(command, holder)
        conditions = []

        lifecycle = holder.lifecycle
        if lifecycle
          froms = lifecycle.transitions.filter_map do |name, transition|
            Array(transition.from) if name.to_s == command.hecks_name
          end.flatten.uniq
          unless froms.empty?
            conditions << "its `#{lifecycle.field}` is currently #{to_sentence_list(froms.map do |f|
              "`#{f}`"
            end, conj: "or")}"
          end
        end

        conditions + command.givens.map(&:description)
      end

      def queries_narrative(queries, holder_name, depth)
        return nil if queries.empty?

        header = DocsProjector.h(depth, "Questions you can ask about #{a_or_an(holder_name)} #{holder_name}")
        lines = queries.map do |query|
          shape   = query.to_h
          takes   = Array(shape[:attributes]).map { |a| Forms::Humanize.label(a[:name].to_s).downcase }
          # `w[:value]` is already `Literal.render`ed (quoted), so no `.inspect`.
          filters = Array(shape[:wheres]).map { |w| "`#{w[:field]}` #{op_words(w[:op])} #{w[:value]}" }

          sentence = "- **#{query.hecks_name}**"
          sentence << " (given #{to_sentence_list(takes)})" unless takes.empty?
          sentence << " — #{query.description}" if query.description
          sentence << "." unless sentence.end_with?(".")
          sentence << " Only where #{to_sentence_list(filters)}." unless filters.empty?
          sentence
        end
        "#{header}\n\n#{lines.join("\n")}"
      end

      def op_words(comparator)
        { eq: "is", lt: "under", lte: "at most", gt: "over", gte: "at least" }[comparator.to_s.to_sym] || comparator.to_s
      end

      def reactions_narrative(bluebook, depth)
        return nil if bluebook.policies.empty? && bluebook.process_managers.empty?

        parts = [DocsProjector.h(depth, "Reactions")]
        bluebook.policies.each do |policy|
          elsewhere = policy.target_domain ? " in #{policy.target_domain}" : ""
          parts << "Whenever `#{policy.on_event}` happens, `#{policy.trigger_command}` fires on its own#{elsewhere} — " \
                   "nobody has to ask for it."
        end

        bluebook.process_managers.each do |saga|
          shape = saga.to_h
          parts << "**#{shape[:name]}** is a saga: it starts when `#{shape[:starts_on]}` happens and ends when " \
                   "`#{shape[:ends_on]}` happens, with each run tracked by its `#{shape[:correlates_by]}`. Along the " \
                   "way it moves through #{Array(shape[:states]).map { |s| "`#{s}`" }.join(" → ")}."
        end
        parts.join("\n\n")
      end

      def to_sentence_list(items, conj: "and") = Naming.to_sentence_list(items, conj: conj)

      # Picks the article for `word`.
      #
      # @return [String] `"a"` or `"an"`
      def a_or_an(word) = Naming.a_or_an(word)
    end
  end
end
