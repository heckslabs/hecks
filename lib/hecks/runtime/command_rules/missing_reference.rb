require_relative "../errors"
require_relative "../refusal_wording"

module Hecks
  module Runtime
    class CommandRules
      # The refusal for a reference whose target identity does not exist.
      module MissingReference
        module_function

        # @param target [Bluebook::Aggregate] the aggregate the reference points at
        # @param key [String] the identity that was not found
        # @param attribute [Symbol] the reference attribute that named it
        # @return [Runtime::NotFound] the refusal, in the `references` stage
        def refusal(target, key, attribute)
          NotFound.new(
            RefusalWording.render_site("NotFound", "reference_target_missing",
                                       target: target.name, heads: target.identity_heads.join(", "), key: key),
            attribute: attribute, stage: :references
          )
        end
      end
    end
  end
end
