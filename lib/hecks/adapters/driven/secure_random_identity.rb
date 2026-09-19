require "securerandom"

module Hecks
  module Adapters
    # The real `identity_generation` fulfillment — an actual random
    # UUID, for an actual deployment. `SequentialIdentity` is the
    # deterministic sibling specs/fuzzing bind instead.
    module SecureRandomIdentity
      module_function

      # Mints a fresh random identity value.
      #
      # @return [String] a newly minted, random UUID
      def uuid = SecureRandom.uuid
    end
  end
end
