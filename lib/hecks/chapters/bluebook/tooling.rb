# Hecks::Chapters::Bluebook::ToolingParagraph
#
# Paragraph covering compiler tooling: the domain compiler,
# in-memory loader, domain inspector, and vertical slice analysis.
#
#   Hecks::Chapters::Bluebook::ToolingParagraph.define(builder)
#
module Hecks
  module Chapters
    module Bluebook
      module ToolingParagraph
        def self.define(b)
          b.aggregate "BluebookCompiler", "Generates domain gems and loads domains into memory" do
            command("Compile") { attribute :domain_id, String; attribute :output_dir, String }
            command("LoadDomain") { attribute :domain_id, String }
            command("BuildStatic") { attribute :domain_id, String; attribute :output_dir, String }
            command("BuildGo") { attribute :domain_id, String; attribute :output_dir, String }
            command("BuildNode") { attribute :domain_id, String; attribute :output_dir, String }
            command("BuildRails") { attribute :domain_id, String; attribute :output_dir, String }
            command("BuildBinary") { attribute :domain_id, String; attribute :output_dir, String }
          end

          b.aggregate "InMemoryLoader", "Fast domain loading without disk I/O via in-memory eval" do
            command("LoadInMemory") { attribute :domain_id, String }
          end

          b.aggregate "DomainInspector", "Top-level introspection across all loaded domains" do
            command("InspectDomain") { attribute :domain_id, String }
          end

          b.aggregate "DomainIntrospector", "Analyzes domain structure programmatically" do
            command("Introspect") { attribute :domain_name, String }
          end

          b.aggregate "GemBuilder", "Packages a domain as a distributable Ruby gem" do
            command("BuildGem") { attribute :domain_name, String }
          end

          b.aggregate "StatementBuilders", "Builds plain-English statements from domain IR objects" do
            command("BuildStatement") { attribute :ir_object, String }
          end

          b.aggregate "TextHelpers", "English text utilities for glossary generation" do
            command("Humanize") { attribute :text, String }
          end

          b.aggregate "BluebookConnections", "Declares what crosses the domain boundary via extend verb" do
            command("Apply") { attribute :extension_name, String }
          end

          b.aggregate "Tokenizer", "Splits command argument strings into typed tokens" do
            command("Tokenize") { attribute :input, String }
          end

          b.aggregate "ExtensionDocs", "Metadata registry describing all Hecks extensions" do
            command("ListExtensions") { attribute :category, String }
          end

          b.aggregate "ReadmeWriter", "Generates per-extension Markdown README files from metadata" do
            command("GenerateReadmes") { attribute :root, String }
          end

          b.aggregate "SourceCollector", "Collects framework source files in load order for binary compilation" do
            command("Collect") { attribute :lib_root, String }
          end

          b.aggregate "ForwardDeclarations", "Generates module forward declarations for the bundled binary" do
            command("Write") { attribute :io, String }
          end

          b.aggregate "BundleWriter", "Concatenates source files into a single self-contained script" do
            command("Write") { attribute :files, String; attribute :output, String }
          end

          b.aggregate "BinaryCompiler", "Orchestrates compilation into a self-contained Ruby script" do
            command("Compile") { attribute :output, String }
          end

          b.aggregate "SourceAnalyzer", "Prism AST analysis of source files for dependency resolution" do
            command("Analyze") { attribute :lib_root, String }
          end

          b.aggregate "ConstantResolver", "Resolves constant references to defining files" do
            command("Resolve") { attribute :ref, String }
          end

          b.aggregate "DependencyGraph", "Builds file-level dependency graph and topological sort" do
            command("Sort") { attribute :lib_root, String }
          end

          b.aggregate "CycleSorter", "Greedy topological sort within dependency cycles" do
            command("SortCycle") { attribute :files, String }
          end

          b.aggregate "SourceTransformer", "Strips requires and expands compact class syntax" do
            command("Transform") { attribute :source, String }
          end

          b.aggregate "ReferenceExtractor", "Extracts constant references from Prism AST" do
            command("Extract") { attribute :source, String }
          end

          b.aggregate "DefinitionExtractor", "Extracts constant definitions from Prism AST" do
            command("Extract") { attribute :source, String }
          end

          b.aggregate "RuntimeGenerator", "Generates runtime wiring modules from domain IR" do
            command("Generate") { attribute :domain_module, String }
          end
        end
      end
    end
  end
end
