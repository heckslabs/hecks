# Hecks::Chapters::Bootstrap::DomainModelParagraph
#
# Paragraph covering the domain model IR: the data structures that
# represent a parsed domain. Structure holds the shape (aggregates,
# entities, value objects), Behavior holds the dynamics (commands,
# events, policies), Names holds naming conventions.
#
#   Hecks::Chapters::Bootstrap::DomainModelParagraph.define(builder)
#
module Hecks
  module Chapters
    module Bootstrap
      module DomainModelParagraph
        def self.define(b)
          b.aggregate "DomainModelStructure", "IR data types for domain shape: Domain, Aggregate, Entity, ValueObject, Attribute, Reference, Lifecycle" do
            command("Parse") { attribute :dsl_source, String }
          end

          b.aggregate "DomainModelBehavior", "IR data types for domain dynamics: Command, Event, Policy, Guard, Query, Scope, Workflow" do
            command("Parse") { attribute :dsl_source, String }
          end

          b.aggregate "DomainModelNames", "Naming conventions for domain concepts: pluralization, module paths, slug generation" do
            command("ModuleName") { attribute :name, String }
            command("Pluralize") { attribute :name, String }
          end

          b.aggregate "SubscriberRegistration", "Tracks event subscriber registrations for policy wiring" do
            command("Register") { attribute :event_name, String; attribute :handler, String }
          end
        end
      end
    end
  end
end
