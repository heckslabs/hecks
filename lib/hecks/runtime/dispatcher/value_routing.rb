module Hecks
  module Runtime
    class Dispatcher
      # Routes a command value to the port operation a hecksagon binds to it: the operations whose
      # `handles` name this command and value (ADR 0163 step 52). Mixed into {Routing}.
      module ValueRouting
        private

        # The port operation a command value is routed to, or nil when no hecksagon binds the
        # command by value. A command that has bindings refuses a value none of them names.
        def value_handler(domain, aggregate, command, call)
          key = command_key(aggregate, command)
          bindings = value_bindings(domain, key)
          return nil if bindings.empty?

          supplied = supplied_values(call)
          found = bindings.find { |_, value| supplied.include?(value) }
          return found.first if found

          no_value_handler!(key, bindings, supplied)
        end

        def command_key(aggregate, command) = "#{aggregate.name}.#{Naming.snake(command.hecks_name)}!"

        # Every port operation of the domain's aggregates that names the command, with its value.
        def value_bindings(domain, key)
          bluebook = @registry.bluebook(domain)
          return [] unless bluebook

          handling_operations(bluebook).flat_map { |operation| bindings_of(operation, key) }
        end

        def handling_operations(bluebook) = bluebook.aggregates.flat_map(&:ports).flat_map(&:operations)

        def bindings_of(operation, key)
          operation.handles.select { |held| held[:command] == key }.map { |held| [operation, held[:value]] }
        end

        # The string values the call supplies, one level down from a value object
        # (`target: {value:}`).
        def supplied_values(call)
          facts = (call.with || {}).merge(call.flat || {})
          facts.values.flat_map { |value| value.is_a?(Hash) ? value.values : [value] }.grep(String)
        end

        def no_value_handler!(key, bindings, supplied)
          handled = bindings.map { |_, value| value }.join(", ")
          raise(UnknownVerb, "#{key} has no handler for #{supplied.inspect}; " \
                             "its hecksagon handles #{handled.inspect}")
        end
      end
    end
  end
end
