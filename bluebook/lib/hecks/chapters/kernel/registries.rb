# Hecks::Chapters::Kernel::RegistriesParagraph
#
# Paragraph describing the registry infrastructure. Covers the base
# Registry and SetRegistry classes, plus all specialized registries
# extended onto the Hecks module (extensions, capabilities, domains,
# targets, adapters, validations, dump formats, grammars, cross-domain,
# and thread context).
#
#   Hecks::Chapters::Kernel::RegistriesParagraph.define(builder)
#
module Hecks
  module Chapters
    module Kernel
      module RegistriesParagraph
        def self.define(b)
          b.aggregate "Registry", "Hash-backed registry for named resources with symbol-coerced keys and Enumerable support" do
            command("Register") { attribute :key, String; attribute :value, String }
            command("Lookup") { attribute :key, String }
          end

          b.aggregate "SetRegistry", "Array-backed registry for unique items with duplicate prevention and Enumerable support" do
            command("RegisterItem") { attribute :item, String }
            command("CheckMembership") { attribute :item, String }
          end

          b.aggregate "ExtensionRegistry", "Extension hook and metadata storage with driven/driving adapter type classification" do
            command("DescribeExtension") { attribute :name, String; attribute :adapter_type, String }
            command("ListDrivenExtensions") { attribute :registry_id, String }
          end

          b.aggregate "CapabilityRegistry", "Registry for domain capabilities that enrich IR by generating constructs at runtime" do
            command("RegisterCapability") { attribute :name, String }
            command("ApplyCapability") { attribute :name, String; attribute :runtime_id, String }
          end

          b.aggregate "DomainRegistry", "Domain caching, load strategy, and last_domain tracking for loaded domains" do
            command("CacheDomain") { attribute :name, String; attribute :domain_id, String }
            command("LookupDomain") { attribute :name, String }
          end

          b.aggregate "CrossDomain", "Cross-domain queries, views, and shared event bus for multi-domain systems" do
            command("RegisterCrossQuery") { attribute :name, String; attribute :source_domain, String }
            command("RegisterCrossView") { attribute :name, String }
          end

          b.aggregate "ThreadContext", "Thread-local tenant and actor context for multi-tenant isolation" do
            command("SetTenant") { attribute :tenant_id, String }
            command("SetActor") { attribute :actor_id, String }
          end

          b.aggregate "TargetRegistry", "Registry for build targets (ruby, static, go, rails) with callable builders" do
            command("RegisterTarget") { attribute :name, String }
            command("BuildTarget") { attribute :name, String; attribute :domain_id, String }
          end

          b.aggregate "AdapterRegistry", "Registry for persistence adapter types (memory, sqlite, postgres) with availability checks" do
            command("RegisterAdapter") { attribute :name, String }
            command("CheckAdapter") { attribute :name, String }
          end

          b.aggregate "ValidationRegistry", "Registry for domain validation rules discoverable without hardcoded constant lists" do
            command("RegisterRule") { attribute :rule_class, String }
            command("ListRules") { attribute :registry_id, String }
          end

          b.aggregate "DumpFormatRegistry", "Registry for serialization formats (schema, swagger, rpc, glossary) with callable handlers" do
            command("RegisterFormat") { attribute :name, String; attribute :description, String }
            command("DumpFormat") { attribute :name, String; attribute :domain_id, String }
          end

          b.aggregate "GrammarRegistry", "Registry for modeling grammars (BlueBook, GameBook) with parser, builder, and entry point" do
            command("RegisterGrammar") { attribute :name, String }
            command("LookupGrammar") { attribute :name, String }
          end
        end
      end
    end
  end
end
