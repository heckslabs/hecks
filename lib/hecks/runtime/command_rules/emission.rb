require_relative "../event"

module Hecks
  module Runtime
    class CommandRules
      # What a command's `emits` becomes: an Event in the registry's log,
      # and — where the store can hold one — a recorded event beside the
      # data it describes.
      module Emission
        # Builds one frozen event per name the command `emits`, appends each to the registry's
        # event log, and records it in the store when the repository keeps events.
        #
        # `correlation` arrives here rather than being merged onto the
        # event afterwards. It is part of the transaction — known from
        # `dispatch`'s own argument before anything is emitted — and an
        # event that is still being written to is not yet a record of
        # what happened. Setting it at construction is what lets the
        # event be frozen the moment it exists.
        #
        # @param command [Bluebook::Command] the command whose `emits` names the events
        # @param domain [String] name of the emitting domain, the prefix of each event's
        #   `aggregate` (`"Domain::Aggregate"`)
        # @param aggregate [Bluebook::Aggregate] the aggregate the record belongs to
        # @param instance [Runtime::Instance] the settled record; its `id` stamps every event
        # @param args [Hash{Symbol => Object}] the normalized command arguments, used as each
        #   event's payload and deep-frozen by this call
        # @param repository [Ports::Persistence::AppendOnly] the aggregate's repository; asked to
        #   `record_event` only if it responds to it
        # @param correlation [Hash, nil] saga correlation head => value for a saga-caused
        #   dispatch; nil otherwise
        # @return [Array<Runtime::Event>] the emitted events in `emits` order, each frozen;
        #   `[]` when the command emits nothing
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
