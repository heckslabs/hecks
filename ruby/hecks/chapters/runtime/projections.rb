# = Hecks::Chapters::Runtime::Projections
#
# Self-describing sub-chapter for CQRS read-model projections:
# view bindings, in-memory projection stores, and projection
# wiring at boot time.
#
#   Hecks::Chapters::Runtime::Projections.define(builder)
#
module Hecks
  module Chapters
    module Runtime
      # Hecks::Chapters::Runtime::Projections
      #
      # Bluebook sub-chapter for CQRS projections: view binding, projection store, and projection setup at boot.
      #
      module Projections
        def self.define(b)
          b.aggregate "ViewBinding", "Wires read model projections to event bus" do
            command("BindView") { attribute :view_name, String }
          end

          b.aggregate "Projection", "CQRS read model projection with in-memory store" do
            command("Apply") { attribute :event_name, String }
            command("Query") { attribute :query_name, String }
          end

          b.aggregate "ProjectionSetup", "Wires CQRS projections to event bus at boot" do
            command("SetupProjections") { attribute :domain_id, String }
          end
        end
      end
    end
  end
end
