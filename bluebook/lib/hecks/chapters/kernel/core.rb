# Hecks::Chapters::Kernel::CoreParagraph
#
# Paragraph describing core infrastructure: error hierarchy, naming
# conventions, autoload registry, module DSL helpers, core extensions,
# domain statistics, event sourcing, and deprecation shims.
#
#   Hecks::Chapters::Kernel::CoreParagraph.define(builder)
#
module Hecks
  module Chapters
    module Kernel
      module CoreParagraph
        def self.define(b)
          b.aggregate "Errors", "Custom error hierarchy: ValidationError, GuardError, ConditionError, DomainLoadError, MigrationError" do
            command("RaiseValidation") { attribute :message, String }
            command("RaiseGuard") { attribute :message, String }
          end

          b.aggregate "Conventions", "Naming helpers and data contracts for cross-target code generation" do
            command("ResolveName") { attribute :input, String; attribute :convention, String }
          end

          b.aggregate "Autoloads", "Central autoload registry mapping every Hecks module to its source file for lazy loading" do
            command("RegisterAutoload") { attribute :module_name, String; attribute :path, String }
          end

          b.aggregate "ModuleDSL", "Declarative helpers providing lazy_registry for lazily-initialized registries on modules" do
            command("DeclareLazyRegistry") { attribute :name, String }
          end

          b.aggregate "CoreExtensions", "Extensions to Ruby core classes used across Hecks modules" do
            command("ExtendCore") { attribute :class_name, String; attribute :method_name, String }
          end

          b.aggregate "Stats", "Domain and project statistics: aggregate counts, attribute counts, command/event/policy metrics" do
            command("ComputeDomainStats") { attribute :domain_id, String }
            command("ComputeProjectStats") { attribute :project_path, String }
          end

          b.aggregate "EventSourcing", "Event sourcing infrastructure: concurrency, CQRS stores, upcasting, projections, outbox, snapshots" do
            command("AppendEvent") { attribute :stream_id, String; attribute :event_name, String }
            command("TakeSnapshot") { attribute :aggregate_id, String }
          end

          b.aggregate "Deprecations", "Registry for deprecated APIs with warning shims prepended onto target classes" do
            command("RegisterDeprecation") { attribute :target_class, String; attribute :method_name, String }
          end
        end
      end
    end
  end
end
