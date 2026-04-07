# Hecks::Chapters::Targets::Node
#
# Paragraph for the Node.js/TypeScript code generation target.
# Covers NodeUtils and all generators that produce TypeScript
# interfaces, commands, repositories, and Express server.
#
#   Hecks::Chapters::Targets::Node.define(builder)
#
module Hecks
  module Chapters
    module Targets
      module Node
        def self.define(b)
          b.aggregate "NodeUtils", "Naming and type mapping: Ruby types to TypeScript types" do
            command("TsType") { attribute :attribute_name, String }
            command("CamelCase") { attribute :input, String }
          end

          b.aggregate "NodeAggregateGenerator", "Generates TypeScript interface for an aggregate root" do
            command("Generate") { attribute :aggregate_name, String }
          end

          b.aggregate "NodeCommandGenerator", "Generates TypeScript command functions returning typed events" do
            command("Generate") { attribute :command_name, String; attribute :aggregate_name, String }
          end

          b.aggregate "NodeRepositoryGenerator", "Generates TypeScript in-memory repository using Map" do
            command("Generate") { attribute :aggregate_name, String }
          end

          b.aggregate "NodeServerGenerator", "Generates Express REST server with JSON routes per aggregate" do
            command("Generate") { attribute :domain_name, String }
          end

          b.aggregate "NodeProjectGenerator", "Generates complete Node/TypeScript project with package.json" do
            command("Generate") { attribute :domain_name, String; attribute :output_dir, String }
          end

          b.aggregate "NodeGenerator", "Top-level coordinator delegating to all Node sub-generators" do
            command("Generate") { attribute :domain_name, String; attribute :output_dir, String }
          end
        end
      end
    end
  end
end
