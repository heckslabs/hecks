# Hecks::Binding
#
# The Binding is the spine of a Bluebook. It holds chapters together:
# module wiring, shared utilities, error hierarchy, registries,
# contracts, cross-chapter event routing, and the compositor that
# loads and connects all chapters.
#
# Hierarchy: bluebook > binding > chapters
#
#   domain = Hecks::Binding.definition
#   domain.aggregates.map(&:name)
#
require_relative "binding/registries"
require_relative "binding/contracts"
require_relative "binding/multi_domain"

module Hecks
  module Binding
    def self.definition
      @definition ||= DSL::DomainBuilder.new("Binding").tap { |b|
        b.aggregate "ModuleDSL", "Declarative lazy_registry helper for modules" do
          command("DefineRegistry") { attribute :name, String }
        end

        b.aggregate "CoreExtensions", "Ruby core class extensions" do
          command("Extend") { attribute :target_class, String }
        end

        b.aggregate "NamingHelpers", "Domain naming convention methods" do
          command("DomainModuleName") { attribute :name, String }
          command("DomainSlug") { attribute :name, String }
        end

        b.aggregate "Utils", "Shared utility functions across framework" do
          command("Underscore") { attribute :string, String }
          command("SanitizeConstant") { attribute :string, String }
        end

        b.aggregate "Errors", "Custom error hierarchy for Hecks" do
          command("Raise") { attribute :error_class, String; attribute :message, String }
        end

        b.aggregate "Deprecations", "Deprecated API shim registry" do
          command("Register") { attribute :target_class, String; attribute :method_name, String }
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

        RegistriesChapter.define(b)
        ContractsChapter.define(b)
        MultiDomainChapter.define(b)
      }.build
    end
  end
end
