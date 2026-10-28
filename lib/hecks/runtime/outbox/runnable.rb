require_relative "../adapter_lookup"
require_relative "../errors"

module Hecks
  module Runtime
    module Outbox
      # Whether this process can run what a redriven row asks of the outside. A policy's `ask` is
      # answered by the adapter bound to its port, and a process that booted without that adapter
      # (a one-shot command that loads no application constants, say) would only turn the row into
      # a refusal nobody sees. It leaves the row pending for a process that has the adapter, and
      # says so once. Mixed into {Relay}, which supplies `registry` and `log`.
      module Runnable
        private

        # Records that a row was left pending, and warns the first time its reason is seen.
        #
        # @return [Boolean] true when the row must not be claimed here
        def withheld?(row)
          reason = unrunnable_reason(row) or return false

          @log << { outbox: row.delivery_id, consumer: row.consumer, withheld: true, reason: reason }
          @withheld_reasons ||= []
          warn withheld_wording(row, reason) if @withheld_reasons.push(reason).count(reason) == 1
          true
        end

        def withheld_wording(row, reason)
          "[hecks] outbox row #{row.delivery_id} (#{row.consumer} on #{row.event[:name]}) left pending: " \
            "#{reason}. A process that has the adapter will run it; it stays visible in `outbox.rows`."
        end

        # @return [String, nil] why the row's ask cannot run in this process, nil when it can
        def unrunnable_reason(row)
          target = ask_target(row) or return nil

          adapter_bound?(*target) ? nil : "no adapter bound for #{target.join(".")} in this process"
        end

        def adapter_bound?(port, operation)
          AdapterLookup.adapter_class(@registry, port, asked: operation)
          true
        rescue WiringError, NameError
          false
        end

        # @return [Array(String, String), nil] the port and operation the row's policy asks, nil
        #   when the row is not an ask
        def ask_target(row)
          kind, fqn = row.consumer.split(":", 2)
          home, name = fqn.split("::", 2)
          policy = kind == "policy" && @registry.bluebook(home)&.policies&.find { |candidate| candidate.name == name }
          return nil unless policy&.asks?

          aggregate_and_port, operation = policy.trigger_command.split(".", 2)
          [aggregate_and_port.split("::").last, operation]
        end
      end
    end
  end
end
