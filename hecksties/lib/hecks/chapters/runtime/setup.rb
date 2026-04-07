# = Hecks::Chapters::Runtime::Setup
#
# Self-describing sub-chapter for runtime boot and setup modules:
# domain loading, extension dispatch, adapter wiring, policy/saga/
# service/workflow registration, and coverage checks.
#
#   Hecks::Chapters::Runtime::Setup.define(builder)
#
module Hecks
  module Chapters
    module Runtime
      # Hecks::Chapters::Runtime::Setup
      #
      # Bluebook sub-chapter for runtime boot and setup: domain loading, extension dispatch, and adapter wiring.
      #
      module Setup
        def self.define(b)
          b.aggregate "BootBluebook", "Boots domains from Bluebook IR" do
            command("Boot") { attribute :bluebook_path, String }
          end

          b.aggregate "BootPhase", "Ordered boot phase execution" do
            command("Execute") { attribute :phase_name, String }
          end

          b.aggregate "ConfigurationDSL", "DSL methods for Hecks.configure block" do
            command("Evaluate") { attribute :config_block, String }
          end

          b.aggregate "ConnectionSetup", "Wires database connections at boot" do
            command("Connect") { attribute :adapter_name, String; attribute :url, String }
          end

          b.aggregate "ConstantHoisting", "Hoists generated classes into constant namespace" do
            command("Hoist") { attribute :module_name, String }
          end

          b.aggregate "DomainConfigBuilder", "Builds domain config from DSL block" do
            command("Build") { attribute :config_block, String }
          end

          b.aggregate "DomainLoader", "Loads domain IR from file or gem" do
            command("LoadFromFile") { attribute :file_path, String }
            command("LoadFromGem") { attribute :gem_name, String }
          end

          b.aggregate "ExtensionDispatch", "Dispatches extension lifecycle hooks" do
            command("Dispatch") { attribute :hook_name, String }
          end

          b.aggregate "LoadExtensions", "Loads and registers extensions at boot" do
            command("Load") { attribute :extension_name, String }
          end

          b.aggregate "PolicySetup", "Wires policy event listeners" do
            command("Wire") { attribute :policy_name, String }
          end

          b.aggregate "PortSetup", "Creates port modules from domain IR" do
            command("Create") { attribute :aggregate_name, String }
          end

          b.aggregate "ReadModelSetup", "Wires read model projections" do
            command("Wire") { attribute :projection_name, String }
          end

          b.aggregate "RepositorySetup", "Creates repository adapters" do
            command("Create") { attribute :adapter_name, String; attribute :aggregate_name, String }
          end

          b.aggregate "SagaSetup", "Registers saga runners" do
            command("Register") { attribute :saga_name, String }
          end

          b.aggregate "ServiceSetup", "Wires service objects with dependency injection" do
            command("Wire") { attribute :service_name, String }
          end

          b.aggregate "ServiceContext", "Execution context for services" do
            command("Build") { attribute :service_name, String }
          end

          b.aggregate "SubscriberSetup", "Registers event subscribers" do
            command("Register") { attribute :event_name, String; attribute :handler, String }
          end

          b.aggregate "ViewSetup", "Wires view projections" do
            command("Wire") { attribute :view_name, String }
          end

          b.aggregate "WorkflowSetup", "Registers workflow executors" do
            command("Register") { attribute :workflow_name, String }
          end

          b.aggregate "CommandDispatch", "Command dispatch pipeline" do
            command("Dispatch") { attribute :command_name, String; attribute :payload, String }
          end

          b.aggregate "AuthCoverageCheck", "Verifies all ports have auth gates" do
            command("Check") { attribute :domain_name, String }
          end

          b.aggregate "ReferenceCoverageCheck", "Verifies reference authorizers exist" do
            command("Check") { attribute :domain_name, String }
          end

          b.aggregate "Versioning", "Runtime version tracking" do
            command("CurrentVersion") { attribute :domain_name, String }
          end

          b.aggregate "CommandLoader", "Generates and evaluates CRUD command and event classes" do
            command("Load") { attribute :aggregate_name, String }
          end

          b.aggregate "QueryContext", "Read-only cross-domain query execution context" do
            command("Execute") { attribute :query_name, String }
          end
        end
      end
    end
  end
end
