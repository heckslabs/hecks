module Hecks
  module ValidationRules
    module Naming

    # Hecks::ValidationRules::Naming::GlossaryTermViolations
    #
    # Enforces ubiquitous language by scanning all domain names (aggregates,
    # attributes, commands, events, value objects, entities, queries, policies)
    # for banned terms declared via the glossary DSL.
    #
    # By default, violations are warnings. When the domain is declared with
    # +glossary(strict: true)+, violations become errors and +valid?+ returns false.
    #
    # Message format:
    #   "Aggregate 'UserProfile' contains avoided term 'user' — prefer 'stakeholder'"
    #
    # Usage:
    #   Hecks.domain "Billing" do
    #     glossary(strict: true) do
    #       prefer "stakeholder", not: ["user", "person"]
    #     end
    #     aggregate "UserProfile" do ...  # => error in strict mode, warning otherwise
    #   end
    #
    class GlossaryTermViolations < BaseRule
      # Returns errors only in strict mode; warnings always populated.
      #
      # @return [Array<String>] error messages (non-empty only when strict: true)
      def errors
        return [] unless strict?
        violations
      end

      # Returns non-blocking warnings when not in strict mode.
      #
      # @return [Array<String>] warning messages (non-empty only when not strict)
      def warnings
        return [] if strict?
        violations
      end

      private

      # @return [Boolean] true if the domain has strict glossary enforcement
      def strict?
        @domain.respond_to?(:glossary_strict) && @domain.glossary_strict
      end

      # @return [Hash{String => String}] map of banned term -> preferred term
      def banned_lookup
        return @banned_lookup if defined?(@banned_lookup)
        @banned_lookup = {}
        Array(@domain.glossary_rules).each do |rule|
          preferred = rule[:preferred].to_s.downcase
          Array(rule[:banned]).each do |banned|
            @banned_lookup[banned.to_s.downcase] = preferred
          end
        end
        @banned_lookup
      end

      # Collect all violations across every named element in the domain.
      #
      # @return [Array<String>] violation messages
      def violations
        return [] if banned_lookup.empty?
        msgs = []
        @domain.aggregates.each do |agg|
          msgs.concat(check_name("Aggregate", agg.name))
          agg.attributes.each   { |a| msgs.concat(check_name("Attribute '#{a.name}' on #{agg.name}", a.name.to_s)) }
          agg.commands.each     { |c| msgs.concat(check_name("Command", c.name)) }
          agg.events.each       { |e| msgs.concat(check_name("Event", e.name)) }
          agg.value_objects.each { |vo|
            msgs.concat(check_name("ValueObject", vo.name))
            vo.attributes.each { |a| msgs.concat(check_name("Attribute '#{a.name}' on #{vo.name}", a.name.to_s)) }
          }
          agg.entities.each { |ent|
            msgs.concat(check_name("Entity", ent.name))
            ent.attributes.each { |a| msgs.concat(check_name("Attribute '#{a.name}' on #{ent.name}", a.name.to_s)) }
          }
          agg.queries.each  { |q| msgs.concat(check_name("Query", q.name)) }
          agg.policies.each { |p| msgs.concat(check_name("Policy", p.name)) }
        end
        msgs
      end

      # Split a name into words (handles PascalCase and snake_case), then check
      # each word against the banned lookup.
      #
      # @param kind [String] human-readable label for error messages
      # @param name [String] the name to check
      # @return [Array<String>] violation messages for this name
      def check_name(kind, name)
        words = split_words(name)
        words.filter_map do |word|
          preferred = banned_lookup[word]
          next unless preferred
          error("#{kind} '#{name}' contains avoided term '#{word}' — prefer '#{preferred}'",
            hint: "Replace '#{word}' with '#{preferred}' in the name")
        end
      end

      # Split a PascalCase or snake_case name into downcased words.
      #
      # @param name [String] the name to split
      # @return [Array<String>] downcased words
      def split_words(name)
        name.to_s
            .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
            .gsub(/([a-z\d])([A-Z])/, '\1_\2')
            .split(/[_\s]+/)
            .map(&:downcase)
            .reject(&:empty?)
      end
    end
    Hecks.register_validation_rule(GlossaryTermViolations)
    end
  end
end
