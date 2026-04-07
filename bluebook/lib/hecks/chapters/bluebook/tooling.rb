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
          b.aggregate "DomainCompiler", "Generates domain gems and loads domains into memory" do
            command("Compile") { attribute :domain_id, String; attribute :output_dir, String }
            command("LoadDomain") { attribute :domain_id, String }
          end

          b.aggregate "InMemoryLoader", "Fast domain loading without disk I/O via in-memory eval" do
            command("LoadInMemory") { attribute :domain_id, String }
          end

          b.aggregate "DomainInspector", "Top-level introspection across all loaded domains" do
            command("InspectDomain") { attribute :domain_id, String }
          end

          b.aggregate "SliceDiagram", "Generates vertical slice diagrams from domain IR" do
            command("GenerateSliceDiagram") { attribute :domain_id, String }
          end

          b.aggregate "SliceExtractor", "Extracts vertical slices from domain command flows" do
            command("ExtractSlices") { attribute :domain_id, String; attribute :entry_command, String }
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

          b.aggregate "DomainConnections", "Declares what crosses the domain boundary via extend verb" do
            command("Extend") { attribute :extension_name, String }
          end

          b.aggregate "Tokenizer", "Splits command argument strings into typed tokens" do
            command("Tokenize") { attribute :input, String }
          end
        end
      end
    end
  end
end
