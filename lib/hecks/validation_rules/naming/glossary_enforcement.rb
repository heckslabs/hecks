module Hecks
  module ValidationRules
    module Naming

    # Hecks::ValidationRules::Naming::GlossaryEnforcement
    #
    # Enforces that attribute names align with the domain's ubiquitous language.
    # The domain vocabulary is built from aggregate names, value object names,
    # and command names (via Domain#auto_glossary). Attribute names that use
    # generic terms not found anywhere in the domain vocabulary trigger warnings.
    #
    # Generic terms that always warn: data, info, value, item, thing, stuff,
    # misc, temp, flag, type (when used alone as the full attribute name).
    #
    # Common abbreviations also warn with a suggestion for the full word.
    #
    # This rule produces warnings only — it never blocks compilation.
    #
    # Usage:
    #   rule = GlossaryEnforcement.new(domain)
    #   rule.warnings  # => ["Attribute 'data' on Pizza is generic..."]
    #
    class GlossaryEnforcement < BaseRule
      ALWAYS_GENERIC = %w[
        data info value item thing stuff misc temp flag type
      ].freeze

      ABBREVIATIONS = {
        "desc"  => "description",
        "qty"   => "quantity",
        "amt"   => "amount",
        "num"   => "number",
        "cnt"   => "count",
        "idx"   => "index",
        "msg"   => "message",
        "addr"  => "address",
        "cfg"   => "configuration",
        "config" => "configuration",
        "impl"  => "implementation",
        "obj"   => "object",
        "ref"   => "reference",
        "attr"  => "attribute",
        "val"   => "value",
        "str"   => "string",
        "btn"   => "button",
        "lbl"   => "label",
        "txt"   => "text",
      }.freeze

      # No errors — this rule only warns.
      #
      # @return [Array] always empty
      def errors
        []
      end

      # Returns warnings for attributes using generic or abbreviated names.
      #
      # @return [Array<ValidationMessage>] warning messages
      def warnings
        vocabulary = build_vocabulary
        msgs = []
        @domain.aggregates.each do |agg|
          msgs.concat(check_attributes(agg.attributes, agg.name, vocabulary))
          agg.value_objects.each do |vo|
            msgs.concat(check_attributes(vo.attributes, vo.name, vocabulary))
          end
          if agg.respond_to?(:entities)
            agg.entities.each do |ent|
              msgs.concat(check_attributes(ent.attributes, ent.name, vocabulary))
            end
          end
        end
        msgs
      end

      private

      # Build vocabulary from the domain's auto_glossary, splitting PascalCase
      # names into individual downcased words. Only includes aggregate, value
      # object, and command names — not attribute names (which are what we check).
      #
      # @return [Set<String>] downcased domain terms
      def build_vocabulary
        terms = Set.new
        Array(@domain.auto_glossary).each do |term|
          split_words(term).each { |w| terms << w }
        end
        terms
      end

      # Check a list of attributes against the vocabulary.
      #
      # @param attributes [Array<Attribute>] attributes to check
      # @param parent_name [String] owning aggregate/VO name for messages
      # @param vocabulary [Set<String>] domain vocabulary words
      # @return [Array<ValidationMessage>] warnings found
      def check_attributes(attributes, parent_name, vocabulary)
        attributes.filter_map do |attr|
          name = attr.name.to_s.downcase
          check_abbreviation(name, parent_name) || check_generic(name, parent_name, vocabulary)
        end
      end

      # Warn if the attribute name is a known abbreviation.
      #
      # @return [ValidationMessage, nil]
      def check_abbreviation(name, parent_name)
        full = ABBREVIATIONS[name]
        return nil unless full
        error(
          "Attribute '#{name}' on #{parent_name} looks like an abbreviation — prefer '#{full}'",
          hint: "Rename '#{name}' to '#{full}'"
        )
      end

      # Warn if the attribute name is generic and not grounded in the domain.
      #
      # @return [ValidationMessage, nil]
      def check_generic(name, parent_name, vocabulary)
        return nil unless ALWAYS_GENERIC.include?(name)
        return nil if vocabulary.include?(name)
        error(
          "Attribute '#{name}' on #{parent_name} is a generic term — use a domain-specific name",
          hint: "Replace '#{name}' with a term from the ubiquitous language"
        )
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
    Hecks.register_validation_rule(GlossaryEnforcement)
    end
  end
end
