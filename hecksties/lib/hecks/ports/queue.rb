  # Hecks::Queue
  #
  # Abstract interface for command queues. Commands are dispatched through
  # the queue instead of executing inline. The default MemoryQueue processes
  # synchronously (same thread); production adapters (Sidekiq, RabbitMQ, SQS)
  # process asynchronously. Swap via +Hecks.boot { queue :sidekiq }+.
  #
  # The queue returns a CommandHandle from +enqueue+, which provides a +wait+
  # method to block until the command completes. This unified interface works
  # for both sync (memory) and async (production) backends.
  #
  # == Usage
  #
  #   handle = Hecks.queue.enqueue("RegisterModel", name: "GPT-5")
  #   result = handle.wait        # blocks until complete (sync: immediate)
  #   handle.completed?           # => true
  #   handle.result               # => the command's return value
  #
module Hecks
  module Queue
    # Handle returned from +enqueue+. Wraps a deferred command execution.
    #
    # Call +.wait+ to block until the command completes and retrieve the result.
    # For MemoryQueue, +.wait+ executes the command immediately on first call.
    # For async adapters, +.wait+ blocks until the background worker finishes.
    class CommandHandle
      # @return [String] the command name (e.g., "RegisterModel")
      attr_reader :command_name

      # @return [Hash] the attributes passed to the command
      attr_reader :attrs

      # @return [String] a unique UUID identifying this queued command
      attr_reader :id

      # Creates a new command handle.
      #
      # @param command_name [String] the name of the command to execute
      # @param attrs [Hash] keyword arguments for the command constructor
      # @param executor [Proc] a callable that executes the command and returns the result
      def initialize(command_name, attrs, executor:)
        @command_name = command_name
        @attrs = attrs
        @id = SecureRandom.uuid
        @executor = executor
        @result = nil
        @completed = false
      end

      # Blocks until the command completes and returns the result.
      #
      # On the first call, invokes the executor to run the command.
      # Subsequent calls return the cached result without re-executing.
      #
      # @param timeout [Integer] maximum seconds to wait (default: 30);
      #   currently only meaningful for async adapters
      # @return [Object] the result of the command execution
      def wait(timeout: 30)
        @result = @executor.call unless @completed
        @completed = true
        @result
      end

      # Returns whether the command has finished executing.
      #
      # @return [Boolean] true if +wait+ has been called and completed
      def completed?
        @completed
      end

      # Returns the cached result of the command execution.
      #
      # Returns nil if the command has not yet been executed (i.e., +wait+
      # has not been called).
      #
      # @return [Object, nil] the command result, or nil if not yet executed
      def result
        @result
      end
    end

    # Default in-memory queue. Processes commands synchronously --
    # +enqueue+ returns a handle, and +.wait+ executes immediately.
    # No persistence, no background threads.
    #
    # This is the queue used in development and testing. For production,
    # swap to an async adapter via the boot configuration.
    class MemoryQueue
      # Creates a new in-memory queue.
      #
      # @param command_resolver [Proc, nil] a callable that receives
      #   +(command_name, attrs)+ and executes the command. If nil,
      #   +execute+ will raise an error.
      def initialize(command_resolver: nil)
        @command_resolver = command_resolver
        @handles = []
      end

      # Enqueues a command for execution.
      #
      # Creates a CommandHandle wrapping the deferred execution. The command
      # is not executed until +handle.wait+ is called. For MemoryQueue, this
      # means execution is synchronous and immediate when +wait+ is invoked.
      #
      # @param command_name [String] the command name (e.g., "RegisterModel")
      # @param attrs [Hash] keyword arguments for the command
      # @return [CommandHandle] a handle to track and await the command result
      def enqueue(command_name, attrs = {})
        executor = -> { execute(command_name, attrs) }
        handle = CommandHandle.new(command_name, attrs, executor: executor)
        @handles << handle
        handle
      end

      # Returns all handles created by this queue instance.
      #
      # @return [Array<CommandHandle>] all enqueued command handles
      def handles
        @handles
      end

      private

      # Executes a command using the configured resolver.
      #
      # @param command_name [String] the command name
      # @param attrs [Hash] the command attributes
      # @return [Object] the result from the command resolver
      # @raise [Hecks::Error] if no command resolver is configured
      def execute(command_name, attrs)
        if @command_resolver
          @command_resolver.call(command_name, attrs)
        else
          raise Hecks::Error, "No command resolver configured for queue"
        end
      end
    end
  end
end
