require_relative "../ask_resolution"

module Hecks
  module Bluebook
    module ModelCheck
      # The checks over `ask`: one that resolves to no declared port operation, a port trigger
      # that should be an ask, and a declared ask no policy reaches.
      module AskChecks
        # @param bluebook [Bluebook::Chapter] the chapter the policy is declared in
        # @param policy [Bluebook::Policy] the policy to check
        # @return [Finding, nil] an error for an `ask` that names no declared ask (or an
        #   ambiguous one), a warning for a `trigger` that names a port operation, else `nil`
        def ask_finding(bluebook, policy)
          return port_trigger_finding(bluebook, policy) unless policy.asks?

          outcome = AskResolution.call(bluebook, policy)
          return if outcome.resolved?

          Finding.new(kind: :unresolved_ask, severity: :error, subject: policy.name, message: outcome.detail)
        end

        # A port operation no policy reaches, by `ask` or by a trigger that names it.
        #
        # @param bluebook [Bluebook::Chapter] the chapter whose aggregates declare the ports
        # @return [Array<Finding>] one warning per outbound operation nothing asks
        def unused_ask_findings(bluebook)
          reached = reached_port_verbs(bluebook)
          bluebook.aggregates.flat_map do |aggregate|
            outbound_operations(aggregate).filter_map do |port, operation|
              verb = "#{aggregate.hecks_name}.#{port.name}.#{operation.hecks_name}"
              next if reached.include?(Naming.split_verb("#{bluebook.name}::#{verb}"))

              Finding.new(kind: :unused_ask, severity: :warning, subject: verb,
                          message: "the hecksagon declares this ask but no policy asks it")
            end
          end
        end

        private

        def port_trigger_finding(bluebook, policy)
          return unless port_operation_verb?(bluebook, policy.trigger_command)

          Finding.new(kind: :port_trigger, severity: :warning, subject: policy.name,
                      message: "trigger #{policy.trigger_command.inspect} names a port operation — " \
                               "write `ask :#{Naming.snake(policy.trigger_command.to_s.split(".").last)}` and " \
                               "let the hecksagon map the port")
        end

        def port_operation_verb?(bluebook, verb)
          qualified = Naming.split_verb("#{bluebook.name}::#{verb}")
          !qualified.nil? && port_verbs_of(bluebook).any? { |held| Naming.split_verb(held) == qualified }
        end

        def reached_port_verbs(bluebook)
          from_policies = bluebook.policies.map { |policy| policy.trigger_command.to_s }
          from_sagas = bluebook.process_managers.flat_map do |manager|
            manager.handlers.flat_map { |handler| handler.dispatches.map(&:command_name) }
          end
          (from_policies + from_sagas).to_set { |verb| Naming.split_verb("#{bluebook.name}::#{verb}") }
        end

        def outbound_operations(aggregate)
          aggregate.ports.flat_map do |port|
            port.operations.select(&:outbound?).map { |operation| [port, operation] }
          end
        end
      end
    end
  end
end
