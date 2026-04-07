# = Hecks::Binding::MultiDomainChapter
#
# Self-describing sub-chapter for multi-domain infrastructure:
# filtered event bus, cross-domain queries and views, directionality
# enforcement, and queue wiring.
#
#   Hecks::Binding::MultiDomainChapter.define(builder)
#
module Hecks
  module Binding
      module MultiDomainChapter
        def self.define(b)
          b.aggregate "FilteredEventBus", "Event bus scoped to specific event types" do
            command("Subscribe") { attribute :event_name, String }
            command("Publish") { attribute :event_name, String }
          end

          b.aggregate "CrossDomainQuery", "Query across domain boundaries" do
            command("Query") { attribute :target_domain, String; attribute :aggregate, String }
          end

          b.aggregate "CrossDomainView", "Projected view spanning multiple domains" do
            command("Project") { attribute :source_domains, String }
          end

          b.aggregate "Directionality", "Enforces upstream/downstream relationships" do
            command("Validate") { attribute :source, String; attribute :target, String }
          end

          b.aggregate "QueueWiring", "Wires cross-domain event queues" do
            command("Wire") { attribute :source_domain, String; attribute :target_domain, String }
          end

          b.aggregate "MultiDomainValidator", "Validates multi-domain configuration" do
            command("Validate") { attribute :domains, String }
          end
        end
      end
    end
end
