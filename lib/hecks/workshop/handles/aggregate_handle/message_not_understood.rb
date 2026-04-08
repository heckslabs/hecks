module Hecks
  class Workshop
    class AggregateHandle
      # Hecks::Workshop::AggregateHandle::MessageNotUnderstood
      #
      # Smalltalk-inspired: unknown messages on an aggregate handle suggest
      # creating a command. Instead of a bare NoMethodError, the user gets
      # a helpful message with the exact code to create the command.
      #
      # This module overrides +method_missing+ on AggregateHandle so that
      # any unrecognized method call produces a NoMethodError whose message
      # includes the list of available commands and a copy-pasteable example
      # for creating the missing command.
      #
      #   Cat.feed
      #   # => Cat doesn't understand 'feed'.
      #   #    Create it with: Cat.command("Feed") { attribute :name, String }
      #
      module MessageNotUnderstood
        include HecksTemplating::NamingHelpers
        # Handle unknown method calls with a helpful suggestion message.
        #
        # Converts the method name to a command-style constant name and raises
        # a NoMethodError that lists available commands and shows how to create
        # the missing one.
        #
        # @param method_name [Symbol] the method that was called
        # @param args [Array] positional arguments (unused)
        # @param kwargs [Hash] keyword arguments (unused)
        # @param block [Proc, nil] block argument (unused)
        # @raise [NoMethodError] always, with a helpful suggestion message
        def method_missing(method_name, *args, **kwargs, &block)
          cmd_name = bluebook_constant_name(method_name.to_s)
          available = commands
          msg = "#{@name} doesn't understand '#{method_name}'."
          if available.any?
            msg += " Available commands: #{available.join(', ')}."
          end
          msg += "\n  Create it with: #{@name}.command(\"#{cmd_name}\") { attribute :name, String }"
          raise NoMethodError, msg
        end

        # Always return false -- no dynamic methods are actually handled.
        #
        # @param method_name [Symbol] the method being checked
        # @param include_private [Boolean] whether to include private methods
        # @return [Boolean] always false
        def respond_to_missing?(method_name, include_private = false)
          false
        end
      end
    end
  end
end
