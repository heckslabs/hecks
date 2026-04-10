# = Hecks::Chapters::Runtime::Core
#
# Self-describing sub-chapter for the core runtime kernel: container
# wiring, configuration, gate enforcement, dry-run preview,
# introspection, domain versioning, and validation.
#
#   Hecks::Chapters::Runtime::Core.define(builder)
#
module Hecks
  module Chapters
    module Runtime
      # Hecks::Chapters::Runtime::Core
      #
      # Bluebook sub-chapter for the core runtime: container, configuration, gates, introspection, versioning, and validation.
      #
      module Core
        def self.define(b)
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
        end
      end
    end
  end
end
