require_relative "../event"

module Hecks
  module Runtime
    class CommandRules
      # Turns a command's `emits` into events in the registry's log and, where possible, the store.
      module Emission
        # Builds one frozen event per name the command `emits` and records each.
        #
        # `correlation` is set at construction so the event can be frozen the moment it exists.
        #
        # @param command [Bluebook::Command] the command whose `emits` names the events
        # @param domain [String] the emitting domain's name
        # @param aggregate [Bluebook::Aggregate] the aggregate the record belongs to
        # @param instance [Runtime::Instance] the settled record; its `id` stamps every event
        # @param args [Hash{Symbol => Object}] the normalized arguments, used as each payload
        # @param repository [Ports::Persistence::AppendOnly] asked to `record_event` if it can
        # @param correlation [Hash, nil] saga correlation for a saga-caused dispatch
        # @return [Array<Runtime::Event>] the emitted events in `emits` order
        def emit(command, domain, aggregate, instance, args, repository, correlation = nil)
          command.emits.map do |event_name|
            event = Event.new(
              name:        event_name,
              aggregate:   "#{domain}::#{aggregate.hecks_name}",
              id:          instance.id,
              payload:     args,
              occurred_at: Time.now.utc.iso8601,
              correlation: correlation
            )
            @registry.event_log << event.emit!
            repository.record_event(event) if repository.respond_to?(:record_event)
            event
          end
        end
      end
    end
  end
end
