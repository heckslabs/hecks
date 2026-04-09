# Hecks::Runtime::Actor::ActorSystem
#
# Manages all aggregate actors for a runtime. Creates mailboxes,
# wires supervisors, provides actor refs. The runtime delegates
# command dispatch to actors instead of calling the command bus
# directly.
#
#   system = ActorSystem.new(runtime)
#   system.actor("Pizza").tell("CreatePizza", name: "Margherita")
#   event = system.actor("Pizza").ask("CreatePizza", name: "Margherita")
#
require_relative "mailbox"
require_relative "supervisor"
require_relative "actor_ref"

module Hecks
  class Runtime
    module Actor
      class ActorSystem
        attr_reader :supervisor

        def initialize(runtime)
          @runtime = runtime
          @actors = {}
          @supervisor = Supervisor.new

          # Create an actor for each aggregate
          runtime.domain.aggregates.each do |agg|
            create_actor(agg.name)
          end
        end

        # Get an actor ref by aggregate name.
        def actor(aggregate_name)
          @actors[aggregate_name.to_s]
        end
        alias_method :[], :actor

        # All actor refs.
        def actors
          @actors.values
        end

        # Dispatch a command through the actor system.
        # Routes to the correct aggregate's mailbox.
        def dispatch(command_name, **args)
          agg_name = resolve_aggregate(command_name)
          ref = @actors[agg_name]
          raise "No actor for aggregate '#{agg_name}'" unless ref
          ref.ask(command_name, **args)
        end

        def stop
          @actors.each_value { |ref| ref.instance_variable_get(:@mailbox).stop }
        end

        private

        def create_actor(aggregate_name)
          bus = @runtime.command_bus
          supervisor = @supervisor

          mailbox = Mailbox.new(aggregate_name) do |cmd, args|
            begin
              bus.dispatch(cmd, **args)
            rescue => e
              supervisor.handle_failure(aggregate_name, e)
              raise
            end
          end

          supervisor.watch(mailbox)
          @actors[aggregate_name] = ActorRef.new(aggregate_name, mailbox: mailbox)
        end

        def resolve_aggregate(command_name)
          @runtime.domain.aggregates.each do |agg|
            return agg.name if agg.commands.any? { |c| c.name == command_name.to_s }
          end
          raise "Command '#{command_name}' not found in any aggregate"
        end
      end
    end
  end
end
