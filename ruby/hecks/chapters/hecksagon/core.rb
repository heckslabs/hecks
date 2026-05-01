# Hecks::Chapters::Hecksagon::CoreParagraph
#
# Paragraph covering the core Hecksagon DSL builders, IR structures,
# and module mixins: gates, ACLs, ports, and domain extension mixins.
#
#   Hecks::Chapters::Hecksagon::CoreParagraph.define(builder)
#
module Hecks
  module Chapters
    module Hecksagon
      module CoreParagraph
        def self.define(b)
          b.aggregate "HecksagonBuilder" do
            description "DSL builder for hexagonal architecture wiring: gates, adapters, extensions"
            namespace "Hecksagon::DSL"
            command("AddGate") { attribute :aggregate, String; attribute :role, String }
            command("SetAdapter") { attribute :type, String }
            command "Build"
          end

          b.aggregate "GateBuilder" do
            description "DSL builder for access control gates on aggregates"
            namespace "Hecksagon::DSL"
            command("Allow") { attribute :methods, String }
            command "Build"
          end

          b.aggregate "GateDefinition" do
            description "Immutable IR structure for a gate (access control on an aggregate)"
            namespace "Hecksagon::Structure"
            command("Create") { attribute :aggregate, String; attribute :role, String }
          end

          b.aggregate "AclDefinition" do
            description "Collects translations for an anti-corruption layer"
            namespace "Hecksagon"
            command("Translate") { attribute :entity, String }
          end

          b.aggregate "DrivenPortRegistry" do
            description "Formalizes adapter registration for driven ports"
            namespace "Hecksagon"
            command("RegisterAdapter") { attribute :name, String; attribute :port, String }
            command("LookupAdapter") { attribute :name, String }
          end

          b.aggregate "ContractValidator" do
            description "Validates that adapters satisfy their driven port contracts at boot time"
            namespace "Hecksagon"
            command "Validate"
          end

          b.aggregate "StrategicDSL" do
            description "Mixin for domain builders adding shared kernels, ACLs, published events"
            namespace "Hecksagon"
            command "SharedKernel"
            command("UseKernel") { attribute :name, String }
            command("AntiCorruptionLayer") { attribute :name, String }
          end

          b.aggregate "ExtensionsDSL" do
            description "Mixin for domain builders declaring driving and driven ports"
            namespace "Hecksagon"
            command("DrivingPort") { attribute :name, String }
            command("DrivenPort") { attribute :name, String }
          end

          b.aggregate "DomainMixin" do
            description "Extends Domain IR objects with hexagonal accessors for ports and kernels"
            namespace "Hecksagon"
            command "Apply"
          end
        end
      end
    end
  end
end
