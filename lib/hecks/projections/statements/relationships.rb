require_relative "../plain_english"
require_relative "../../bluebook/one_of_union"

module Hecks
  module Projections
    module Statements
      # What one thing holds or points at, said from its attribute's name, target and cardinality.
      # A reference stored under its target's own name reads as belonging; one stored under a
      # role ("source", "disputed_by") keeps the role, so two references to one target differ.
      #
      #   Relationships.sentence(transfer, source) # => "Each transfer has one source account."
      module Relationships
        PREPOSITIONS = %w[by to for from with of on in at].freeze

        # The built-in value types, which a list names by its field rather than its element.
        PRIMITIVES = %w[String Integer Float TrueClass FalseClass Boolean].freeze

        # A past participle's ending, as a role's first word carries it: "disputed", "drawn".
        PARTICIPLE = /(ed|en|wn)\z/

        module_function

        # @param holder [Bluebook::Aggregate, Bluebook::Entity] the construct the attribute is on
        # @param attribute [Bluebook::Attribute] one of its attributes
        # @return [String, nil] the sentence, or nil for a plain field
        def sentence(holder, attribute)
          subject = "Each #{PlainEnglish.noun(holder.hecks_name)}"
          return list_sentence(subject, attribute) if attribute.list?
          return nil unless attribute.relationship
          return union_sentence(subject, holder, attribute) if Bluebook::OneOfUnion.union?(attribute)

          "#{subject} #{reference_phrase(attribute)}."
        end

        # "Each hold points at its subject: one account or ATM card." (ADR 0122)
        def union_sentence(subject, holder, attribute)
          targets = Bluebook::OneOfUnion.variants(holder, attribute).map { |name| PlainEnglish.noun(name) }
          verb = attribute.optional? ? "can point at" : "points at"
          "#{subject} #{verb} its #{PlainEnglish.noun(attribute.name)}: one #{targets.join(" or ")}."
        end

        # "Each order holds a list of toppings." The element is named when the field is not
        # simply its plural: "Each account holds its ledger, a list of ledger entries."
        def list_sentence(subject, attribute)
          field = PlainEnglish.noun(attribute.name)
          element = element_noun(attribute)
          return "#{subject} holds a list of #{field}." if element.nil? || field.end_with?(element)

          "#{subject} holds its #{field}, a list of #{element}."
        end

        # The plural element noun, or nil for a list of plain values (text, numbers).
        def element_noun(attribute)
          type = attribute.type
          name = type.respond_to?(:target_name) ? type.target_name : type.to_s
          return nil if PRIMITIVES.include?(name) || name.include?("<")

          PlainEnglish.plural(PlainEnglish.noun(name))
        end

        # The verb phrase after "Each <holder>".
        def reference_phrase(attribute)
          type = attribute.type
          target_name = type.target_name
          target = PlainEnglish.noun(target_name)
          return own_name_phrase(attribute, target) if Naming.snake(target_name) == attribute.name.to_s

          role = PlainEnglish.noun(attribute.name)
          return prepositional_phrase(role, target, attribute.optional?) if PREPOSITIONS.include?(role.split.last)

          role_phrase(role, target, attribute.optional?)
        end

        # "belongs to one customer", or "has one" for `has_one`; "can" when it is optional.
        def own_name_phrase(attribute, target)
          has = attribute.relationship == "has_one"
          return "#{has ? "can have" : "can belong to"} one #{target}" if attribute.optional?

          "#{has ? "has" : "belongs to"} one #{target}"
        end

        # "can be disputed by one customer", "reports to at most one employee".
        def prepositional_phrase(role, target, optional)
          if role.split.first.match?(PARTICIPLE)
            optional ? "can be #{role} one #{target}" : "is #{role} one #{target}"
          else
            optional ? "#{role} at most one #{target}" : "#{role} one #{target}"
          end
        end

        # "has one source account"; a role that already ends in its target is not repeated.
        def role_phrase(role, target, optional)
          named = role.end_with?(target.split.last) ? role : "#{role} #{target}"
          optional ? "can have one #{named}" : "has one #{named}"
        end
      end
    end
  end
end
