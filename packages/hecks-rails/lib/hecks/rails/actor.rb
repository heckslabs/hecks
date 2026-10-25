module Hecks
  module Rails
    # Who a request acts as. By default it is the app's `current_user`: its `actor_id` if it defines
    # one, else its `id`. That id is what Governance holds role grants against.
    #
    # An app whose users are named differently declares the lookup once, in an initializer:
    #
    #     Hecks::Rails.actor_from { |controller| controller.current_account&.uuid }
    module Actor
      # @yieldparam controller [ActionController::Base] the controller handling the request
      # @yieldreturn [String, nil] the actor's id, or nil for an anonymous request
      # @return [void]
      def actor_from(&block) = @actor_from = block

      # @param controller [ActionController::Base] the controller handling the request
      # @return [Hash{Symbol => String}, nil] `{ actor_id: }`, or nil when nobody is signed in
      def actor_for(controller)
        id = @actor_from ? @actor_from.call(controller) : signed_in_id(controller)
        id ||= picked_id(controller) if dev_actor?
        id && { actor_id: id.to_s }
      end

      # Whether the pages offer an "acting as" picker, which signs in as a role with no password.
      # Only a development server offers it unless the app says so.
      #
      # @return [Boolean] true on a development server, else whatever `dev_actor=` set
      def dev_actor? = @dev_actor.nil? ? ::Rails.env.development? : @dev_actor

      # @param value [Boolean, nil] true or false to decide, nil to follow the environment
      # @return [void]
      def dev_actor=(value)
        @dev_actor = value
      end

      private

      # The id the picker signed the session in as, granted again when this process has not seen it.
      def picked_id(controller)
        return unless controller.respond_to?(:session)

        actor = controller.session[:hecks_actor]
        role = controller.session[:hecks_role]
        DevActor.grant(actor, role) if actor && role
        actor
      end

      def signed_in_id(controller)
        user = controller.respond_to?(:current_user, true) ? controller.send(:current_user) : nil
        return unless user

        user.respond_to?(:actor_id) ? user.actor_id : user.id
      end
    end
  end
end
