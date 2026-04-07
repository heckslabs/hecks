# = Hecks::Binding::RegistriesChapter
#
# Self-describing sub-chapter for all Hecks registries: domain,
# adapter, extension, capability, grammar, target, validation,
# dump format, thread context, and cross-domain.
#
#   Hecks::Binding::RegistriesChapter.define(builder)
#
module Hecks
  module Binding
      module RegistriesChapter
        def self.define(b)
          b.aggregate "DomainRegistry", "Tracks loaded domain modules" do
            command("Register") { attribute :domain_name, String }
            command("Lookup") { attribute :domain_name, String }
          end

          b.aggregate "AdapterRegistry", "Registers persistence adapters" do
            command("Register") { attribute :adapter_name, String }
            command("Lookup") { attribute :adapter_name, String }
          end

          b.aggregate "ExtensionRegistry", "Registers extension modules" do
            command("Register") { attribute :extension_name, String }
            command("Apply") { attribute :extension_name, String }
          end

          b.aggregate "CapabilityRegistry", "Registers domain capabilities" do
            command("Register") { attribute :capability_name, String }
            command("Apply") { attribute :capability_name, String }
          end

          b.aggregate "GrammarRegistry", "Registers DSL grammar providers" do
            command("Register") { attribute :grammar_name, String }
          end

          b.aggregate "TargetRegistry", "Registers build targets (ruby, go, node)" do
            command("Register") { attribute :target_name, String }
            command("Build") { attribute :target_name, String }
          end

          b.aggregate "ValidationRegistry", "Registers domain validation rules" do
            command("Register") { attribute :rule_name, String }
          end

          b.aggregate "DumpFormatRegistry", "Registers export formats (schema, swagger)" do
            command("Register") { attribute :format_name, String }
            command("Dump") { attribute :format_name, String }
          end

          b.aggregate "ThreadContext", "Thread-local state (actor, tenant)" do
            command("SetActor") { attribute :actor, String }
            command("SetTenant") { attribute :tenant_id, String }
          end

          b.aggregate "CrossDomainRegistry", "Tracks cross-domain event subscriptions" do
            command("Subscribe") { attribute :source_domain, String; attribute :event, String }
          end
        end
      end
    end
end
