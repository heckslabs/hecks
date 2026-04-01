module Hecks
  class DomainGlossary
    # Hecks::DomainGlossary::StatementBuilders
    #
    # Builds plain-English statements from domain IR objects -- attributes,
    # commands, policies, and relationships. Mixed into DomainGlossary to
    # keep sentence construction logic separate from the traversal logic.
    #
    # Each method takes domain IR objects and returns a human-readable string
    # describing that element in natural language.
    #
    module StatementBuilders
      private

      # Build a statement describing a single attribute on an aggregate.
      # Handles three cases: list attributes ("has many"), reference attributes
      # ("belongs to"), and scalar attributes ("has a/an").
      #
      # @param agg_name [String] the aggregate name for sentence subject
      # @param attr [Hecks::DomainModel::Attribute] the attribute to describe
      # @return [String] a plain-English sentence about this attribute
      def attribute_statement(agg_name, attr)
        a = an(agg_name)
        if attr.list?
          "#{a} has many #{pluralize(attr.type.to_s)}."
        else
          "#{a} has #{article(attr.name.to_s)} #{attr.name} (#{attr.type})."
        end
      end

      # Build a statement describing a command and its resulting event.
      # Extracts the verb from the command name (e.g., "Create" from
      # "CreatePizza"), lists command parameters, and describes the
      # domain event that results.
      #
      # @param agg_name [String] the aggregate name
      # @param cmd [Hecks::DomainModel::Command] the command to describe
      # @param event [Hecks::DomainModel::Event, nil] the resulting event, or nil
      # @return [String] a plain-English sentence about this command flow
      def command_statement(agg_name, cmd, event)
        verb = cmd.name.split(/(?=[A-Z])/).first.downcase
        attrs = cmd.attributes.map { |a| a.name.to_s.tr("_", " ") }
        params = attrs.empty? ? "" : " with #{english_list(attrs)}"
        if event
          event_parts = event.name.split(/(?=[A-Z])/)
          past_verb = event_parts.first.downcase
          event_noun = event_parts[1..].join
          subject = event_noun.empty? ? an(agg_name, capitalize: false) : an(event_noun, capitalize: false)
          result = " When this happens, #{subject} is #{past_verb}."
        else
          result = ""
        end
        "You can #{verb} #{an(agg_name, capitalize: false)}#{params}.#{result} (command)"
      end

      # Build a statement describing a reactive policy. Explains that when
      # a specific event occurs, the system triggers a specific command,
      # optionally asynchronously.
      #
      # @param agg_name [String] the aggregate or domain name for context
      # @param pol [Hecks::DomainModel::Policy] the policy to describe
      # @return [String] a plain-English sentence about this policy chain
      def policy_statement(agg_name, pol)
        trigger_verb = pol.trigger_command.split(/(?=[A-Z])/).first.downcase
        trigger_target = pol.trigger_command.split(/(?=[A-Z])/)[1..].join
        async_note = pol.async ? " (asynchronously)" : ""
        event_parts = pol.event_name.split(/(?=[A-Z])/)
        verb = event_parts.first.downcase
        noun = event_parts[1..].join
        subject = noun.empty? ? an(agg_name, capitalize: false) : an(noun, capitalize: false)
        "When #{subject} is #{verb}, the system will #{trigger_verb} #{trigger_target}#{async_note}. (policy)"
      end

      # Build the "Ubiquitous Language" section from glossary rules.
      # Renders each defined/preferred term with its definition and
      # any avoided synonyms.
      #
      # @return [Array<String>] lines of markdown describing the glossary terms,
      #   or an empty array if there are no glossary rules
      def describe_ubiquitous_language
        rules = Array(@domain.glossary_rules)
        return [] if rules.empty?

        lines = []
        lines << "## Ubiquitous Language"
        lines << ""
        rules.each do |rule|
          term = rule[:preferred]
          defn = rule[:definition]
          banned = Array(rule[:banned])
          line = "- **#{term}**"
          line += " -- #{defn}" if defn
          line += " (avoid: #{banned.join(', ')})" unless banned.empty?
          lines << line
        end
        lines << ""
        lines
      end

      # Build the "Relationships" section listing all cross-aggregate
      # references in the domain. Scans all aggregates for reference-type
      # attributes and generates one sentence per reference.
      #
      # @return [Array<String>] lines of markdown describing relationships,
      #   or an empty array if there are no cross-aggregate references
      def describe_relationships
        lines = []
        refs = []
        @domain.aggregates.each do |agg|
          (agg.references || []).each do |ref|
            refs << [agg.name, ref.type]
          end
        end

        return lines if refs.empty?

        lines << "## Relationships"
        lines << ""
        refs.each do |from, to|
          lines << "#{an(from)} references #{an(to, capitalize: false)}."
        end
        lines
      end
    end
  end
end
