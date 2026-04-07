# = Hecks::Chapters::Runtime::EventSourcingChapter
#
# Self-describing sub-chapter for event sourcing infrastructure:
# event store, snapshots, upcasting, projections, outbox, process
# managers, time travel, and reconstitution.
#
#   Hecks::Chapters::Runtime::EventSourcingChapter.define(builder)
#
module Hecks
  module Chapters
    module Runtime
      # Hecks::Chapters::Runtime::EventSourcingChapter
      #
      # Bluebook sub-chapter for event sourcing: event store, snapshots, upcasting, projections, and process managers.
      #
      module EventSourcingChapter
        def self.define(b)
          b.aggregate "EventStore", "Append-only event log per aggregate stream" do
            command("Append") { attribute :stream_id, String; attribute :event, String }
            command("ReadStream") { attribute :stream_id, String }
          end

          b.aggregate "SnapshotStore", "Periodic aggregate state snapshots" do
            command("Save") { attribute :stream_id, String; attribute :snapshot, String }
            command("Load") { attribute :stream_id, String }
          end

          b.aggregate "UpcasterRegistry", "Registers event version upcasters" do
            command("Register") { attribute :event_type, String; attribute :version, Integer }
          end

          b.aggregate "UpcasterEngine", "Applies upcasters to old event versions" do
            command("Upcast") { attribute :event, String }
          end

          b.aggregate "ProjectionRebuilder", "Rebuilds read models from event history" do
            command("Rebuild") { attribute :projection_name, String }
          end

          b.aggregate "Reconstitution", "Rebuilds aggregate from events + snapshot" do
            command("Reconstitute") { attribute :stream_id, String }
          end

          b.aggregate "TimeTravel", "Query aggregate state at a point in time" do
            command("At") { attribute :stream_id, String; attribute :timestamp, String }
          end

          b.aggregate "ProcessManager", "Long-running event-driven coordinator" do
            command("Handle") { attribute :event, String }
          end

          b.aggregate "OutboxES", "Transactional outbox for reliable event publishing" do
            command("Enqueue") { attribute :event, String }
          end

          b.aggregate "OutboxPoller", "Polls outbox and publishes pending events" do
            command("Poll") { attribute :batch_size, Integer }
          end

          b.aggregate "Concurrency", "Optimistic concurrency version stamps" do
            command("Stamp") { attribute :aggregate, String; attribute :version, Integer }
          end

          b.aggregate "EventSourcing", "Top-level module for event sourcing concerns with autoload registry" do
            command("Autoload") { attribute :const_name, String; attribute :path, String }
          end
        end
      end
    end
  end
end
