require_relative "../event"

module Hecksagain
  module Runtime
    class CommandRules
      # What a command's `emits` becomes: an Event in the registry's log,
      # and — where the store can hold one — a recorded event beside the
      # data it describes.
      module Emission
        def emit(command, domain, aggregate, instance, args, repository)
          command.emits.map do |event_name|
            event = Event.new(
              name:        event_name,
              aggregate:   "#{domain}::#{aggregate.hecks_name}",
              id:          instance.id,
              payload:     args,
              occurred_at: Time.now.utc.iso8601
            )
            @registry.event_log << event
            repository.record_event(event) if repository.respond_to?(:record_event)
            event
          end
        end
      end
    end
  end
end
