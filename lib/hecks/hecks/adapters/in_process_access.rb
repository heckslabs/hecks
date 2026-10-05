# frozen_string_literal: true

require_relative "first_admin"

module Hecks
  module Adapters
    # What the `DomainRuntime` port's adapter does when an `Operation` asks it to give a domain its
    # first administrator.
    module InProcessAccess
      # Boots the domain and grants the first administrator through its membership chapter.
      #
      # @param held [Hash] the `Operation` record: `subject` (the domain), `email`, and optionally
      #   `name` and `role`
      # @return [Hash{Symbol => Hash}] `output:` the sentence saying who now holds which role
      # @raise [Runtime::NotFound] if the domain cannot be found or has no membership chapter, or an
      #   administrator already exists
      def bootstrap(**held)
        result = FirstAdmin.new(boot(held[:subject])).call(
          email: plain(held[:email]), name: plain(held[:name]), role: plain(held[:role])
        )
        output(result.to_s)
      end
    end
  end
end
