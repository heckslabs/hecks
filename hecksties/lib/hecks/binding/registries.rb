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
    # Hecks::Binding::RegistriesChapter
    #
    # Bluebook sub-chapter defining all Hecks registry aggregates: domain, adapter, extension, capability, and more.
    #
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

          b.aggregate "AdapterRegistryMethods", "Lazy registry methods for adapter types (memory, sqlite, etc.) extended onto Hecks" do
            command("RegisterAdapter") { attribute :name, String }
          end

          b.aggregate "CapabilityRegistryMethods", "Lazy registry methods for domain capabilities extended onto Hecks" do
            command("RegisterCapability") { attribute :name, String }
          end

          b.aggregate "DomainRegistryMethods", "Lazy registry for domain IR caching and load strategy extended onto Hecks" do
            command("SetLoadStrategy") { attribute :strategy, String }
          end

          b.aggregate "ExtensionRegistryMethods", "Lazy registry for driven/driving extension hooks and metadata extended onto Hecks" do
            command("DescribeExtension") { attribute :name, String; attribute :adapter_type, String }
          end

          b.aggregate "TargetRegistryMethods", "Lazy registry for build targets (ruby, go, rails) extended onto Hecks" do
            command("RegisterTarget") { attribute :name, String }
          end

          b.aggregate "ValidationRegistryMethods", "Lazy registry for domain validation rule classes extended onto Hecks" do
            command("RegisterRule") { attribute :rule_class, String }
          end

          b.aggregate "DumpFormatRegistryMethods", "Lazy registry for dump/serialization formats (schema, swagger) extended onto Hecks" do
            command("RegisterFormat") { attribute :name, String; attribute :desc, String }
          end

          b.aggregate "GrammarRegistryMethods", "Lazy registry for modeling vocabularies (BlueBook, GameBook) extended onto Hecks" do
            command("RegisterGrammar") { attribute :name, String }
          end

          b.aggregate "GrammarDescriptor", "Descriptor holding parser, builder, entry point, and type map for a grammar" do
            command("Configure") { attribute :name, String }
          end

          b.aggregate "CrossDomainMethods", "Cross-domain queries, views, and shared event bus methods extended onto Hecks" do
            command("RegisterQuery") { attribute :name, String }
          end

          b.aggregate "ThreadContextMethods", "Thread-local tenant, actor, and current_user context methods extended onto Hecks" do
            command("SetContext") { attribute :key, String; attribute :value, String }
          end
        end
      end
    end
end
