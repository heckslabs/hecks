# = Hecks::Chapters::Runtime
#
# Self-describing chapter for the Hecks runtime layer. Covers the
# runtime container, command/event dispatch, ports, mixins, event
# sourcing, sagas, workflows, and domain versioning.
#
#   domain = Hecks::Chapters::Runtime.definition
#   domain.aggregates.map(&:name)
#
module Hecks
  module Chapters
    require_paragraphs(__FILE__)

    # Hecks::Chapters::Runtime
    #
    # Bluebook chapter defining the Hecks runtime: command dispatch, ports, mixins, event sourcing, and sagas.
    #
    module Runtime
      def self.definition
        @definition ||= DSL::DomainBuilder.new("Runtime").tap { |b|
          b.aggregate "Runtime", "Wires domain IR to adapters, dispatches commands, publishes events" do
            command("Boot") { attribute :domain_path, String }
            command("Load") { attribute :domain_ir, String }
            command("Configure") { attribute :config_block, String }
          end

          b.aggregate "Configuration", "Application wiring: adapters, extensions, domain loading" do
            command("SetAdapter") { attribute :adapter_name, String }
            command("AddExtension") { attribute :extension_name, String }
            command("LoadDomain") { attribute :domain_name, String }
          end

          b.aggregate "GateEnforcer", "Restricts aggregate access by gate role" do
            command("EnforceGate") { attribute :gate_name, String; attribute :aggregate_name, String }
          end

          b.aggregate "DryRunResult", "Previews command execution without side effects" do
            command("DryRun") { attribute :command_name, String }
          end

          b.aggregate "SagaRunner", "Executes multi-step sagas with compensation" do
            command("StartSaga") { attribute :saga_name, String }
          end

          b.aggregate "SagaStore", "Persists saga state across steps" do
            command("SaveState") { attribute :saga_id, String; attribute :state, String }
          end

          b.aggregate "WorkflowExecutor", "Runs multi-step workflows with branching" do
            command("ExecuteWorkflow") { attribute :workflow_name, String }
          end

          b.aggregate "ViewBinding", "Wires read model projections to event bus" do
            command("BindView") { attribute :view_name, String }
          end

          b.aggregate "Introspection", "Runtime inspection of aggregates, commands, events" do
            command("Inspect") { attribute :aggregate_name, String }
          end

          b.aggregate "DomainVersioning", "Snapshot-based domain version management" do
            command("TagVersion") { attribute :version, String }
            command("LoadVersion") { attribute :version, String }
            command("DiffVersions") { attribute :from_version, String; attribute :to_version, String }
          end

          b.aggregate "Validations", "Domain validation rule enforcement" do
            command("Validate") { attribute :aggregate, String }
          end

          b.aggregate "SmokeTest", "Browser-style HTTP smoke tests for domains" do
            command("RunSmoke") { attribute :base_url, String }
            command("CheckEvents") { attribute :event_log, String }
            command("TestBehaviors") { attribute :domain_name, String }
          end

          Chapters.define_paragraphs(Runtime, b)
        }.build
      end
    end
  end
end
