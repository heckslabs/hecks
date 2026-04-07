# Hecks::Chapters::Targets::Go
#
# Paragraph for the Go code generation target. Covers GoCodeBuilder,
# GoUtils, and all Go generators that produce domain structs, commands,
# events, server, and runtime.
#
#   Hecks::Chapters::Targets::Go.define(builder)
#
module Hecks
  module Chapters
    module Targets
      module Go
        def self.define(b)
          b.aggregate "GoCodeBuilder", "Fluent builder for Go source files: packages, imports, structs, methods" do
            command("Struct") { attribute :name, String }
            command("Receiver") { attribute :type_name, String; attribute :method_name, String }
            command("Func") { attribute :name, String; attribute :params, String }
            command("Render") { attribute :package, String }
          end

          b.aggregate "GoUtils", "Naming and type mapping: Ruby types to Go types, case conversion" do
            command("GoType") { attribute :attribute_name, String }
            command("PascalCase") { attribute :input, String }
          end

          b.aggregate "GoAggregateGenerator", "Generates Go struct for aggregate root with validations" do
            command("Generate") { attribute :aggregate_name, String; attribute :package, String }
          end

          b.aggregate "GoCommandGenerator", "Generates Go command struct with Execute method" do
            command("Generate") { attribute :command_name, String; attribute :aggregate_name, String }
          end

          b.aggregate "GoEventGenerator", "Generates immutable Go event struct with OccurredAt" do
            command("Generate") { attribute :event_name, String; attribute :aggregate_name, String }
          end

          b.aggregate "GoLifecycleGenerator", "Generates Go lifecycle: status type, state constants, transitions" do
            command("Generate") { attribute :aggregate_name, String; attribute :package, String }
          end

          b.aggregate "GoPolicyGenerator", "Generates Go reactive policy structs wired to event bus" do
            command("Generate") { attribute :policy_name, String; attribute :package, String }
          end

          b.aggregate "GoQueryGenerator", "Generates Go query functions with field-matching filter" do
            command("Generate") { attribute :query_name, String; attribute :aggregate_name, String }
          end

          b.aggregate "GoSpecificationGenerator", "Generates Go specification structs with SatisfiedBy predicate" do
            command("Generate") { attribute :spec_name, String; attribute :aggregate_name, String }
          end

          b.aggregate "GoValueObjectGenerator", "Generates Go struct for value objects with constructor validation" do
            command("Generate") { attribute :value_object_name, String; attribute :package, String }
          end

          b.aggregate "GoPortGenerator", "Generates Go interface for repository ports" do
            command("Generate") { attribute :aggregate_name, String; attribute :package, String }
          end

          b.aggregate "GoMemoryAdapterGenerator", "Generates Go in-memory repository using sync.RWMutex" do
            command("Generate") { attribute :aggregate_name, String; attribute :package, String }
          end

          b.aggregate "GoErrorsGenerator", "Generates Go error types matching the hecks error hierarchy" do
            command("Generate") { attribute :package, String }
          end

          b.aggregate "GoApplicationGenerator", "Generates Go runtime entry point with command dispatch" do
            command("Generate") { attribute :module_path, String }
          end

          b.aggregate "GoRuntimeGenerator", "Generates Go runtime: event bus, command bus, domain event interface" do
            command("GenerateEventBus")
            command("GenerateCommandBus")
          end

          b.aggregate "GoRegistryGenerator", "Generates thread-safe module registry for Go runtime discovery" do
            command("Generate")
          end

          b.aggregate "GoRegisterGenerator", "Generates init() that self-registers domain with registry" do
            command("Generate") { attribute :domain_name, String; attribute :module_path, String }
          end

          b.aggregate "GoServerGenerator", "Generates Go HTTP server with JSON API, HTML UI, and behavior routes" do
            command("Generate") { attribute :domain_name, String; attribute :module_path, String }
          end

          b.aggregate "DataRoutes", "Mixin generating Go JSON API CRUD routes for each aggregate" do
            command("Generate") { attribute :domain_name, String }
          end

          b.aggregate "HtmlRoutes", "Mixin generating Go HTML index/show routes for each aggregate" do
            command("Generate") { attribute :domain_name, String }
          end

          b.aggregate "UIRoutes", "Mixin generating Go form submission and new-entity routes" do
            command("Generate") { attribute :domain_name, String }
          end

          b.aggregate "DomainBehaviorRoutes", "Mixin generating Go event, query, scope, and specification routes" do
            command("Generate") { attribute :domain_name, String }
          end

          b.aggregate "GoRendererGenerator", "Generates Go template renderer with layout wrapping" do
            command("Generate")
          end

          b.aggregate "GoViewGenerator", "Converts ERB templates to Go html/template syntax" do
            command("Convert") { attribute :template_name, String }
          end

          b.aggregate "GoFormTemplate", "Generates Go html/template for form pages with field types" do
            command("Generate")
          end

          b.aggregate "GoIndexTemplate", "Generates Go html/template for index pages with action buttons" do
            command("Generate")
          end

          b.aggregate "GoShowTemplate", "Generates Go html/template for show pages with lifecycle fields" do
            command("Generate")
          end

          b.aggregate "GoProjectGenerator", "Generates complete Go project: structs, commands, server, go.mod" do
            command("Generate") { attribute :domain_name, String; attribute :output_dir, String }
          end

          b.aggregate "GoMultiProjectGenerator", "Generates multi-domain Go project with shared runtime" do
            command("Generate") { attribute :output_dir, String }
          end

          b.aggregate "GoMultiServerGenerator", "Generates combined Go HTTP server routing across bounded contexts" do
            command("Generate") { attribute :module_path, String }
          end

          b.aggregate "BinaryBuilder", "Compiles domain into native binary via Go target" do
            command("Build") { attribute :domain_id, String; attribute :output_dir, String }
          end
        end
      end
    end
  end
end
