# = Hecks::Binding::ContractsChapter
#
# Self-describing sub-chapter for data contracts that guarantee
# cross-target consistency. Each contract defines naming and shape
# rules for a specific concern (types, events, routes, etc.).
#
#   Hecks::Binding::ContractsChapter.define(builder)
#
module Hecks
  module Chapters
    module Binding
    # Hecks::Binding::ContractsChapter
    #
    # Bluebook chapter defining the Contracts aggregate for cross-target data contract registration.
    #
      module ContractsChapter
        def self.define(b)
          b.aggregate "Contracts", "Contract registry for cross-target parity" do
            command("Register") { attribute :name, String; attribute :contract, String }
            command("Lookup") { attribute :name, String }
          end

          b.aggregate "TypeContract", "Attribute type mapping rules" do
            command("ResolveType") { attribute :type_name, String }
          end

          b.aggregate "AggregateContract", "Aggregate shape and naming rules" do
            command("Validate") { attribute :aggregate_name, String }
          end

          b.aggregate "CommandContract", "Command naming and attribute rules" do
            command("Validate") { attribute :command_name, String }
          end

          b.aggregate "EventContract", "Event naming and payload rules" do
            command("Validate") { attribute :event_name, String }
          end

          b.aggregate "EventLogContract", "Event log format and storage rules" do
            command("Validate") { attribute :log_entry, String }
          end

          b.aggregate "RouteContract", "HTTP route naming and path rules" do
            command("Validate") { attribute :route_path, String }
          end

          b.aggregate "DisplayContract", "Display label and formatting rules" do
            command("Format") { attribute :value, String }
          end

          b.aggregate "ViewContract", "Read model projection rules" do
            command("Validate") { attribute :view_name, String }
          end

          b.aggregate "FormParsingContract", "HTTP form parameter parsing rules" do
            command("Parse") { attribute :params, String }
          end

          b.aggregate "UILabelContract", "UI label generation rules" do
            command("Generate") { attribute :field_name, String }
          end

          b.aggregate "MigrationContract", "Schema migration naming rules" do
            command("Validate") { attribute :migration_name, String }
          end

          b.aggregate "DispatchContract", "Command dispatch routing rules" do
            command("Validate") { attribute :command_name, String }
          end

          b.aggregate "ExtensionContract", "Extension registration and wiring rules" do
            command("Validate") { attribute :extension_name, String }
          end

          b.aggregate "CsrfContract", "CSRF token generation and validation" do
            command("Validate") { attribute :token, String }
          end

          b.aggregate "NamingContract", "Domain naming conventions" do
            command("Validate") { attribute :name, String }
          end

          b.aggregate "DispatchNotAllowed", "Raised when dispatch target is not a declared command, query, or CRUD builtin" do
            command("Throw") { attribute :agg_name, String; attribute :method_name, String }
          end
        end
        end
      end
    end
end
