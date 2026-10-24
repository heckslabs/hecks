module Hecks
  module Runtime
    # What a dispatch step asks its context for, answered from the record, command and
    # aggregate the context holds. Mixed into each interpreter's `Context` struct, which
    # supplies the readers (`instance`, `command`, `aggregate`, `route`, ...) these read.
    module DispatchContext
      # @return [Hash{Symbol => Object}] the record's held state
      def state = instance.state

      # @return [Object] the record's identity
      def instance_id = instance.id

      # @return [Integer, nil] the version the record was read at, nil when never stored
      def instance_version = instance.version

      # @return [Symbol] what the repository answered the save with (`:stale`, `:conflicted`, ...)
      def outcome_status = persistence_outcome.status

      # @return [String] the aggregate's declared name
      def aggregate_hecks_name = aggregate.hecks_name

      # @return [String] the command's declared name
      def command_hecks_name = command.hecks_name

      # @return [Array] the command's ensures clauses
      def command_ensures = command.ensures

      # @return [Array] the command's mutations, in declaration order
      def command_mutations = command.mutations

      # @return [Object] the state the admitted transition moves to
      def transition_target = transition.target

      # @return [Object] what the repository can do (CAS, locking, atomic put)
      def capabilities = repository.capabilities

      # @return [Object, nil] the aggregate identity the route names, nil without a route
      def routed_identity = route&.aggregate
    end
  end
end
