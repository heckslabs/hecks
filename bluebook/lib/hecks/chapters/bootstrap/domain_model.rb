# Hecks::Chapters::Bootstrap::BluebookModelParagraph
#
# Paragraph covering the domain model IR: the data structures that
# represent a parsed domain. Structure holds the shape (aggregates,
# entities, value objects), Behavior holds the dynamics (commands,
# events, policies), Names holds naming conventions.
#
#   Hecks::Chapters::Bootstrap::BluebookModelParagraph.define(builder)
#
module Hecks
  module Chapters
    module Bootstrap
      module BluebookModelParagraph
        def self.define(b)
          b.aggregate "BluebookModelStructure", "IR data types for domain shape: Domain, Aggregate, Entity, ValueObject, Attribute, Reference, Lifecycle" do
            command("Parse") { attribute :dsl_source, String }
          end

          b.aggregate "BluebookModelBehavior", "IR data types for domain dynamics: Command, Event, Policy, Guard, Query, Scope, Workflow" do
            command("Parse") { attribute :dsl_source, String }
          end

          b.aggregate "BluebookModelNames", "Naming conventions for domain concepts: pluralization, module paths, slug generation" do
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
