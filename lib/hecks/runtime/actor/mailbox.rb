# Hecks::Runtime::Actor::Mailbox
#
# Ordered command queue for an aggregate actor. Ensures commands
# to the same aggregate process sequentially — no races, no
# concurrent mutations. Thread-safe via Mutex.
#
#   mailbox = Mailbox.new("Pizza") { |cmd, args| runtime.command_bus.dispatch(cmd, **args) }
#   mailbox.tell("CreatePizza", name: "Margherita")  # async, returns immediately
#   result = mailbox.ask("CreatePizza", name: "Margherita")  # sync, waits for result
#
module Hecks
  class Runtime
    module Actor
      class Mailbox
        attr_reader :aggregate_name, :queue_size

        def initialize(aggregate_name, &handler)
          @aggregate_name = aggregate_name
          @handler = handler
          @queue = ::Queue.new
          @queue_size = 0
          @mutex = Mutex.new
          @thread = start_processor
        end

        # Fire-and-forget — enqueue command, return immediately.
        def tell(command_name, **args)
          @mutex.synchronize { @queue_size += 1 }
          @queue << { command: command_name, args: args, callback: nil }
        end

        # Send and wait — enqueue command, block until result.
        def ask(command_name, **args)
          result_queue = ::Queue.new
          @mutex.synchronize { @queue_size += 1 }
          @queue << { command: command_name, args: args, callback: result_queue }
          result_queue.pop
        end

        # How many commands are waiting.
        def pending
          @mutex.synchronize { @queue_size }
        end

        def stop
          @queue << :stop
          @thread.join(2)
        end

        private

        def start_processor
          Thread.new do
            loop do
              msg = @queue.pop
              break if msg == :stop
              process(msg)
              @mutex.synchronize { @queue_size -= 1 }
            end
          end
        end

        def process(msg)
          result = @handler.call(msg[:command], msg[:args])
          msg[:callback]&.push(result)
        rescue => e
          msg[:callback]&.push(e)
        end
      end
    end
  end
end
