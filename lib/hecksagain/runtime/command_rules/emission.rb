require_relative "../event"

module Hecksagain
  module Runtime
    class CommandRules
      # What a command's `emits` becomes: an Event in the registry's log,
      # and — where the store can hold one — a recorded event beside the
      # data it describes.
      module Emission
        # `correlation` arrives HERE rather than being merged onto the
        # event afterwards. It is part of the transaction — known from
        # `dispatch`'s own argument before anything is emitted — and an
        # event that is still being written to is not yet a record of
        # what happened. Setting it at construction is what lets the
        # event be frozen the moment it exists.
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
