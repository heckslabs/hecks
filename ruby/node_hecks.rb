# = NodeHecks
#
# Node.js/TypeScript domain generator for Hecks. Loaded from the
# Targets::Node Bluebook chapter — the chapter lists every aggregate,
# and load_aggregates derives the require tree from naming conventions.
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

Hecks::Chapters.load_aggregates(
  Hecks::Targets::Node,
  base_dir: File.expand_path("node_hecks", __dir__)
)

# Self-register Node target when loaded
Hecks.register_target(:node) do |domain, output_dir: ".", **|
  valid, errors = Hecks.validate(domain)
  raise Hecks::ValidationError.for_domain(errors) unless valid

  NodeHecks::ProjectGenerator.new(domain, output_dir: output_dir).generate
end
