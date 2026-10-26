module Hecks
  module Rails
    # Which of a record's commands would pass for an actor right now, answered by the domain's own
    # validation: lifecycle state, the actor's Governance grants and every `given`, saving nothing.
    #
    # A command that still needs arguments the actor has yet to supply is listed when nothing but
    # those arguments stand in the way: the role is checked first, so a role the actor lacks refuses
    # before any argument is looked at. The domain stops at the arguments, so the record's own state
    # is asked of the same rules the dispatch uses, which read no argument.
    class AvailableCommands
      # @param door [Module] the aggregate's module in the booted domain
      # @param handle [Object] the record in hand
      def initialize(door, handle)
        @door = door
        @handle = handle
      end

      # @param actor_id [String] the actor to answer for
      # @return [Array<Symbol>] the names of the commands that would pass, as the bare verb
      def call(actor_id:)
        Hecks.as_caller(role: "", actor_id: actor_id) do
          commands.select { |command| available?(command) }.map { |command| Naming.snake(command.hecks_name).to_sym }
        end
      end

      private

      def commands = @door.ir.commands.reject(&:creates?)

      def available?(command) = state_admits?(command) && only_arguments_missing?(command)

      def only_arguments_missing?(command)
        verb = "#{@handle.fqn}.#{command.hecks_name}"
        Booted.dispatcher.validate(verb, to: @handle.id, with: {}).refusals.all? { |refusal| refusal.stage == :arguments }
      end

      # Whether the record's lifecycle state lets the command run, as the domain decides it.
      def state_admits?(command)
        Booted.dispatcher.state_admits?(@handle.fqn.split("::").first, @door.ir, command, @handle.id)
      end
    end
  end
end
