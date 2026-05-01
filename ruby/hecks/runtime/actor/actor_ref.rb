# Hecks::Runtime::Actor::ActorRef
#
# Location-transparent handle to an aggregate actor. The caller
# doesn't know if the actor is local (in-process mailbox) or
# remote (over WebSocket/HTTP). Same interface either way.
#
#   ref = ActorRef.new("Pizza", mailbox: local_mailbox)
#   ref.tell("CreatePizza", name: "Margherita")   # async
#   event = ref.ask("CreatePizza", name: "Marg")   # sync
#
module Hecks
  class Runtime
    module Actor
      class ActorRef
        attr_reader :aggregate_name

        def initialize(aggregate_name, mailbox:)
          @aggregate_name = aggregate_name
          @mailbox = mailbox
        end

        # Fire-and-forget.
        def tell(command_name, **args)
          @mailbox.tell(command_name, **args)
        end

        # Send and wait for result.
        def ask(command_name, **args)
          @mailbox.ask(command_name, **args)
        end

        # How many messages are queued.
        def pending
          @mailbox.pending
        end
      end
    end
  end
end
