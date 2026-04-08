# Hecks::Chapters::Binding
#
# The Binding chapter holds chapters together: module wiring, shared
# utilities, error hierarchy, registries, contracts, cross-chapter
# event routing, and the compositor that loads and connects all chapters.
#
#   domain = Hecks::Chapters::Binding.definition
#   domain.aggregates.map(&:name)
#
module Hecks
  module Chapters
    require_paragraphs(__FILE__)

    # Hecks::Chapters::Binding
    #
    # Bluebook chapter for framework binding: module wiring, error hierarchy, registries, contracts, and event routing.
    #
    module Binding
      def self.definition
        @definition ||= DSL::BluebookBuilder.new("Binding").tap { |b|
          b.aggregate "ModuleDSL", "Declarative lazy_registry helper for modules" do
            command("DefineRegistry") { attribute :name, String }
          end

          b.aggregate "CoreExtensions", "Ruby core class extensions" do
            command("Apply") { attribute :target_class, String }
          end

          b.aggregate "NamingHelpers", "Domain naming convention methods" do
            command("DomainModuleName") { attribute :name, String }
            command("DomainSlug") { attribute :name, String }
          end

          b.aggregate "Utils", "Shared utility functions across framework" do
            command("Underscore") { attribute :string, String }
            command("SanitizeConstant") { attribute :string, String }
          end

          b.aggregate "Deprecations", "Deprecated API shim registry" do
            command("Register") { attribute :target_class, String; attribute :method_name, String }
          end

          b.aggregate "HecksDeprecations", "Top-level deprecated API shim module that prepends warning methods onto target classes" do
            command("Register") { attribute :target_class, String; attribute :method_name, String }
          end

          b.aggregate "Registry", "Hash-backed registry for named resources with symbol-coerced keys and Enumerable support" do
            command("Register") { attribute :key, String; attribute :value, String }
            command("Lookup") { attribute :key, String }
          end

          b.aggregate "SetRegistry", "Array-backed registry for unique items with duplicate prevention and Enumerable support" do
            command("Register") { attribute :item, String }
          end

          b.aggregate "Stats", "Framework usage statistics: aggregate counts, attribute counts, command/event/policy metrics" do
            command("Compute") { attribute :domain_name, String }
          end

          b.aggregate "ExtensionDocs", "Metadata registry for extension gems" do
            command("ListExtensions") { attribute :format, String }
          end

          b.aggregate "TestHelper", "Auto-reset support module for test suites" do
            command("Reset") { attribute :scope, String }
          end

          b.aggregate "Autoloads", "Central autoload registry for lazy loading" do
            command("Register") { attribute :module_name, String; attribute :path, String }
          end

          b.aggregate "Version", "Framework version (CalVer)" do
            command("Show") { attribute :format, String }
          end

          b.aggregate "BindingSpine", "Top-level binding module holding chapters together with module wiring" do
            command("Define") { attribute :name, String }
          end

          Chapters.define_paragraphs(Binding, b)
        }.build
      end
    end
  end
end
