# Hecks::Chapters::Targets::SchemaParagraph
#
# Paragraph covering schema-oriented generators: TypeScript types,
# JSON Schema, OpenAPI specs, and RPC discovery manifests.
#
#   Hecks::Chapters::Targets::SchemaParagraph.define(builder)
#
module Hecks
  module Chapters
    module Targets
      module SchemaParagraph
        def self.define(b)
          b.aggregate "TypescriptGenerator", "Generates TypeScript type definitions from domain IR" do
            command("GenerateTypescript") { attribute :domain_id, String; attribute :output_dir, String }
          end

          b.aggregate "JsonSchemaGenerator", "Generates JSON Schema from domain aggregate structure" do
            command("GenerateJsonSchema") { attribute :aggregate_id, String }
          end

          b.aggregate "OpenapiGenerator", "Generates OpenAPI 3.0 specification from domain IR" do
            command("GenerateOpenapi") { attribute :domain_id, String }
          end

          b.aggregate "RpcDiscovery", "Generates RPC service discovery manifest from domain commands" do
            command("GenerateRpcDiscovery") { attribute :domain_id, String }
          end
        end
      end
    end
  end
end
