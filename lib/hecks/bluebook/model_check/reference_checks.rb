module Hecks
  module Bluebook
    module ModelCheck
      # The checks over how aggregates relate: an attribute that copies another aggregate's
      # identity by value, where `reference_to` would state the link and have it enforced.
      module ReferenceChecks
        # Types that name no aggregate's identity, however many aggregates declare one of them.
        PRIMITIVE_TYPES = %w[String Integer Float Boolean Date DateTime Time Symbol JSON Hash Array].freeze

        # Every check over how aggregates relate: a link copied by value, a reference that outlives
        # the record it names (OrphanChecks), and a branch on a tagged reference (OneOfChecks).
        #
        # @param bluebook [Bluebook::Chapter] the assembled chapter to check
        # @return [Array<Finding>] the three checks' findings, in that order
        def reference_findings(bluebook)
          [*key_by_value_findings(bluebook), *orphan_findings(bluebook), *one_of_branch_findings(bluebook)]
        end

        # Flags each scalar attribute whose type is the identity type of another aggregate in
        # this domain and that is not itself a reference: the link exists only by convention.
        #
        # @param bluebook [Bluebook::Chapter] the assembled chapter to check
        # @return [Array<Finding>] one :key_by_value warning per such attribute
        def key_by_value_findings(bluebook)
          owners = identity_type_owners(bluebook)
          bluebook.aggregates.flat_map do |aggregate|
            aggregate.attributes.filter_map { |attribute| key_by_value_finding(aggregate, attribute, owners) }
          end
        end

        # @return [Hash{String => Array<String>}] each identity attribute's type, to the names
        #   of the aggregates whose identity it is
        def identity_type_owners(bluebook)
          bluebook.aggregates.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |aggregate, owners|
            identity_types(aggregate).each { |type| owners[type] << aggregate.hecks_name }
          end
        end

        # A composite identity is several facts (a timestamp among them is no key to copy), so
        # only a single-head identity counts.
        #
        # @return [Array<String>] the type of the aggregate's identity attribute, if it has
        #   exactly one and it is neither a reference, a list nor a primitive
        def identity_types(aggregate)
          return [] unless aggregate.identity_heads.size == 1

          attribute = aggregate.attribute(aggregate.identity_heads.first)
          attribute && valued_attribute?(attribute) ? [attribute.type.to_s] : []
        end

        # @return [Boolean] whether the attribute is one scalar of a named, non-primitive type
        def valued_attribute?(attribute)
          return false if attribute.reference? || attribute.list?

          !PRIMITIVE_TYPES.include?(attribute.type.to_s)
        end

        # An owner's single identity attribute is the key itself; being one head of a composite
        # identity is not, since that aggregate still copies the key by value.
        def own_identity?(aggregate, attribute)
          aggregate.identity_heads == [attribute.name.to_sym]
        end

        def key_by_value_finding(aggregate, attribute, owners)
          return unless valued_attribute?(attribute)
          return if own_identity?(aggregate, attribute)

          target = (owners.fetch(attribute.type.to_s, []) - [aggregate.hecks_name]).first
          return unless target

          Finding.new(kind: :key_by_value, severity: :warning,
                      subject: "#{aggregate.hecks_name}.#{attribute.name}",
                      message: "#{attribute.type} matches #{target}'s identity by value, " \
                               "so nothing enforces the link; use reference_to #{target}")
        end
      end
    end
  end
end
