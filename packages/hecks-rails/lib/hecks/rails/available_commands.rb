module Hecks
  module Rails
    # Which of a record's commands would pass for an actor right now, answered by the domain's own
    # dry run: lifecycle state, the actor's Governance grants and every `given`, with nothing saved.
    #
    # A command that still needs arguments the actor has yet to supply is listed when its role is
    # held, because the dry run refuses an absent argument before it reaches the role gate.
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
          commands.select { |command| available?(command, actor_id) }.map { |command| Naming.snake(command.hecks_name).to_sym }
        end
      end

      private

      def commands = @door.ir.commands.reject(&:creates?)

      def available?(command, actor_id)
        Booted.dispatcher.dry_run?("#{@handle.fqn}.#{command.hecks_name}", **identity)
      rescue Hecks::Refused => e
        e.kind == :absent_argument && role_held?(command, actor_id)
      end

      def identity = { @door.ir.identified_by => @handle.id }

      def role_held?(command, actor_id)
        role = command.role.to_s
        role.empty? || Hecks::Ports::Authorization.holds_role?(Booted.registry, actor_id: actor_id, role: role)
      end
    end
  end
end
