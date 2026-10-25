module Hecks
  module Rails
    # The grant behind the development picker: tells Governance that `dev-<role>` holds its role.
    #
    # A session outlives a server whose store is in memory, so the grant is made again for a
    # session that names one, once for each actor in a process.
    module DevActor
      module_function

      # @param actor [String] the actor's id
      # @param role [String] the role the actor holds
      # @return [void]
      def grant(actor, role)
        return if granted.include?([actor, role])

        assign(actor, role)
        granted << [actor, role]
      end

      # @return [void] forgets what was granted, as a restarted process would
      def reset! = @granted = nil

      def granted = @granted ||= Set.new

      def assign(actor, role)
        Booted.dispatcher.dispatch_flat("Governance::RoleAssignment.Assign",
                                        actor_id: { value: actor }, role_name: { value: role },
                                        scope: { value: "Main" }, starts_at: { value: Date.current.iso8601 })
      rescue Hecks::Refused
        nil # already held: the grant outlives the session
      end
    end
  end
end
