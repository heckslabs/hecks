# = NodeHecks
#
# Node.js/TypeScript domain generator for Hecks. Produces a complete
# Express + TypeScript project from the same domain IR the Ruby and
# Go generators read. Same DSL, TypeScript output.
#
# == Usage
#
#   require "node_hecks"
#   domain = Hecks.domain("Pizzas") { ... }
#   NodeHecks::ProjectGenerator.new(domain).generate
#
#   # Or via CLI:
#   hecks build --target node
#
# Register Node.js/TypeScript type mappings with the TypeContract registry
Hecks::Conventions::TypeContract.register_target(:node, {
  "String"   => "string",
  "Integer"  => "number",
  "Float"    => "number",
  "Boolean"  => "boolean",
  "TrueClass" => "boolean",
  "FalseClass" => "boolean",
  "Date"     => "string",
  "DateTime" => "string",
  "JSON"     => "Record<string, unknown>",
}, default: "string")

require_relative "node_hecks/node_utils"
require_relative "node_hecks/generators/aggregate_generator"
require_relative "node_hecks/generators/command_generator"
require_relative "node_hecks/generators/repository_generator"
require_relative "node_hecks/generators/server_generator"
require_relative "node_hecks/generators/project_generator"
require_relative "node_hecks/generators/node_generator"
