# Hecks::Chapters::Bluebook::GeneratorInternalsParagraph
#
# Paragraph covering generator infrastructure classes: base
# generator, file writing, spec writing, skeleton generation,
# self-host diffing, and framework gem generation.
#
#   Hecks::Chapters::Bluebook::GeneratorInternalsParagraph.define(builder)
#
module Hecks
  module Chapters
    module Bluebook
      module GeneratorInternalsParagraph
        def self.define(b)
          b.aggregate "Generator", "Base generator class with shared IR walking and file emission" do
            command("Generate") { attribute :construct_id, String; attribute :output_dir, String }
          end

          b.aggregate "FileWriter", "Writes generated source files to disk with diff support" do
            command("WriteFile") { attribute :path, String; attribute :content, String }
          end

          b.aggregate "SpecWriter", "Writes generated RSpec files for domain constructs" do
            command("WriteSpec") { attribute :construct_id, String; attribute :output_dir, String }
          end

          b.aggregate "LlmsTxtWriter", "Generates llms.txt documentation files from domain IR" do
            command("WriteLlmsTxt") { attribute :domain_id, String; attribute :output_dir, String }
          end

          b.aggregate "SpecHelpers", "Shared helpers for spec file generation across construct types" do
            command("GenerateHelper") { attribute :construct_type, String }
          end

          b.aggregate "InjectionHelpers", "Dependency injection helpers for command generator wiring" do
            command("InjectDependency") { attribute :command_id, String; attribute :dependency, String }
          end

          b.aggregate "FileLocator", "Locates actual source files on disk by aggregate name" do
            command("LocateFile") { attribute :aggregate_name, String; attribute :root, String }
          end

          b.aggregate "SkeletonGenerator", "Generates skeleton file structures from domain IR" do
            command("GenerateSkeleton") { attribute :domain_id, String; attribute :output_dir, String }
          end

          b.aggregate "SelfHostDiff", "Compares generated files against actual source for self-hosting" do
            command("DiffSelfHost") { attribute :domain_id, String }
          end

          b.aggregate "FrameworkGemGenerator", "Generates framework gem skeletons with gemspec and structure" do
            command("GenerateFrameworkGem") { attribute :name, String; attribute :output_dir, String }
          end

          b.aggregate "Registry", "Generator registry for pluggable code generation" do
            command("RegisterGenerator") { attribute :name, String }
          end

          b.aggregate "Infrastructure", "Parent module for infrastructure generators" do
            command("Generate") { attribute :domain_id, String }
          end

          b.aggregate "BuiltIn", "Registers all built-in generators with the registry" do
            command("RegisterAll") { attribute :domain_id, String }
          end
        end
      end
    end
  end
end
