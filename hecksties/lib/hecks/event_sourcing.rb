# Hecks::EventSourcing
#
# Top-level module for all event-sourcing concerns: optimistic concurrency,
# CQRS read model stores, event upcasting, projections, outbox, process
# managers, snapshots, and time travel. Each sub-module is autoloaded.
#
# == Usage
#
#   require "hecks/event_sourcing"
#   Hecks::EventSourcing::Concurrency.stamp!(agg, 1)
#   Hecks::EventSourcing::EventStore.new.append("Pizza-1", event)
#
module Hecks
  module EventSourcing
    autoload :Concurrency,       "hecks/event_sourcing/concurrency"
    autoload :VersionCheckStep,  "hecks/event_sourcing/version_check_step"
    autoload :ReadModelStore,    "hecks/event_sourcing/read_model_store"
    autoload :EventStore,        "hecks/event_sourcing/event_store"
    autoload :UpcasterRegistry,  "hecks/event_sourcing/upcaster_registry"
    autoload :UpcasterEngine,    "hecks/event_sourcing/upcaster_engine"
    autoload :ProjectionRebuilder, "hecks/event_sourcing/projection_rebuilder"
    autoload :Outbox,            "hecks/event_sourcing/outbox"
    autoload :OutboxStep,        "hecks/event_sourcing/outbox_step"
    autoload :OutboxPoller,      "hecks/event_sourcing/outbox_poller"
    autoload :ProcessManager,    "hecks/event_sourcing/process_manager"
    autoload :SnapshotStore,     "hecks/event_sourcing/snapshot_store"
    autoload :Reconstitution,    "hecks/event_sourcing/reconstitution"
    autoload :TimeTravel,        "hecks/event_sourcing/time_travel"
  end
end
