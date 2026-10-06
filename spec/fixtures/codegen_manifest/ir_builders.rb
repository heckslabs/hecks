# The small IR hashes the planted-gaps fixture assembles: queries, commands, read models, ports and
# the clauses they carry, each with the nil and empty defaults an exported domain would hold.
module ManifestIrBuilders
  def active = where_clause("status", "eq", "\"active\"")

  def where_clause(field, operator, value) = { field: field, op: operator, value: value }

  def mutation(target, operator, source, sign: "") = { target: target, op: operator, sign: sign, source: source }

  def argument(name) = { kind: "argument", name: name }

  def literal(value) = { kind: "literal", value: value }

  def head(aggregate, as_name) = { aggregate: aggregate, as: as_name, many: true }

  def port(name, operation, attributes) = { name: name, operations: [{ name: operation, attributes: attributes, emits: [] }] }

  def deep_copy(value) = Marshal.load(Marshal.dump(value))

  def query(name, wheres, **options)
    { name: name, description: nil, attributes: [], wheres: wheres, order_by: nil, limit: nil }.merge(options)
  end

  def command(name, mutations, attributes = [])
    { name: name, role: nil, goal: nil, references: nil, attributes: attributes, givens: [], ensures: [],
      mutations: mutations, emits: [], from: nil, provenance: nil }
  end

  def read_model(name, heads, **options)
    { name: name, description: nil, reference_name: nil, reference_target: nil, query_name: name.downcase,
      wheres: [], order_by: nil, limit: nil, aggregate_heads: heads, group_by: [] }.merge(options)
  end

  def attribute(name, type, list: false)
    { name: name, type: type, list: list, default: nil, optional: false, pattern: nil, admits: nil, relationship: nil }
  end
end
