require_relative "../adapters/driving/handle"

module Hecks
  class Router
    class NamespaceInstaller
      # One aggregate's repository and event log, read through its dispatcher.
      AggregateReader = Struct.new(:dispatcher, :domain, :aggregate) do
        # @param entry [Router::Entry] a router entry
        # @return [AggregateReader, nil] the reader for the entry's aggregate; nil for a
        #   query/command-only entry
        #   whose owner isn't a real aggregate root
        def self.for(entry)
          aggregate = entry.aggregate
          new(entry.dispatcher, entry.domain, aggregate) if aggregate
        end

        def repository = dispatcher.repository(domain, aggregate)

        def events
          fqn = "#{domain}::#{aggregate.hecks_name}"
          dispatcher.events.select { |event| event.aggregate == fqn }
        end

        def find(id)
          found = repository.find(id)
          found && handle(found)
        end

        def all = repository.all.map { |instance| handle(instance) }

        def handle(instance)
          Adapters::Driving::Handle.new(dispatcher: dispatcher, domain: domain, aggregate: aggregate, instance: instance)
        end
      end
    end
  end
end
