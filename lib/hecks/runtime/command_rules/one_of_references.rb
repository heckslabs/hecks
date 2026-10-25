require_relative "../errors"
require_relative "../refusal_wording"
require_relative "../value"
require_relative "../../bluebook/one_of_union"

module Hecks
  module Runtime
    class CommandRules
      # Refuses a tagged reference (`reference_to one_of(A, B)`, ADR 0122) whose record does not
      # exist in the aggregate its `type` names. `admits:` has already refused a type outside the
      # union, so only the lookup is left here.
      module OneOfReferences
        # Checks every tagged reference `construct` holds in settled `state`.
        #
        # @param domain [String, Symbol] the domain whose repositories are read
        # @param construct [Bluebook::Aggregate] the aggregate whose state was settled
        # @param state [Hash{Symbol => Object}] the record's settled fields
        # @return [void]
        # @raise [Runtime::NotFound] if a tagged reference names a record that does not exist
        def resolve_one_of_references(domain, construct, state)
          Bluebook::OneOfUnion.attributes(construct).each do |attribute|
            tagged = Value.materialize_unwrapped(state[attribute.name])
            next unless tagged.is_a?(Hash)

            validate_tagged_reference(domain, construct, tagged)
          end
        end

        private

        # Looks the tagged record up in the repository of the aggregate its `type` names.
        def validate_tagged_reference(domain, construct, tagged)
          target = construct.hecks_owner&.aggregate(tagged[:type].to_s)
          key = tagged[:id].to_s
          return if target.nil? || key.empty? || @registry.repository(domain, target).find(key)

          raise NotFound,
                RefusalWording.render_site("NotFound", "reference_target_missing",
                                           target: target.name, heads: target.identity_heads.join(", "), key: key)
        end
      end
    end
  end
end
