module Hecks
  module Rails
    # The development picker's one route: signs the session in as a role, or out. It exists only
    # while `Hecks::Rails.dev_actor?` holds, because it signs anyone in without a password.
    #
    # The actor is named for its role (`dev-chef`) and Governance is told it holds that role, so the
    # domain's own checks decide what it may do.
    class ActorsController < ActionController::Base
      before_action { head :not_found unless Hecks::Rails.dev_actor? }

      # @return [void] redirects back to the page the person was on
      def create
        role = params[:role].to_s
        role.empty? ? sign_out : sign_in_as(role)
        redirect_back fallback_location: "/", allow_other_host: false
      end

      private

      def sign_out = session.delete(:hecks_actor) && session.delete(:hecks_role)

      def sign_in_as(role)
        actor = "dev-#{Naming.snake(role)}"
        grant(actor, role)
        session[:hecks_actor] = actor
        session[:hecks_role] = role
      end

      def grant(actor, role)
        Booted.dispatcher.dispatch_flat("Governance::RoleAssignment.Assign",
                                        actor_id: { value: actor }, role_name: { value: role },
                                        scope: { value: "Main" }, starts_at: { value: Date.current.iso8601 })
      rescue Hecks::Refused
        nil # already held: the grant outlives the session
      end
    end
  end
end
