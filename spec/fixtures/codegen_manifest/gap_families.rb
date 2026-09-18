# EVERY SKIP FAMILY, PLANTED — the corpus generates everything today, so
# its manifests carry no gaps and the two generators' `construct` choices
# would never be compared. This adds one ungeneratable query, read model,
# command, port operation and aggregate per construct family to a copy of
# banking's committed IR (`call` mutates the Hash it is given), for
# spec/codegen_manifest_parity_spec.rb to run through both generators.
module ManifestGapFamilies
  module_function

  # Every construct `call` plants; the spec checks each lands in the manifest.
  CONSTRUCTS = %w[
    attribute_type owning_aggregate
    cursor index_hints no_wheres where_unrecognized_field reference_hop_where where_none_in_state where_literal
    order_by limit offset authorization
    mutation_op state_source set_literal port_attribute_type
    arithmetic clamp set_argument_bridge remove_field corrects_reverses
    group_by missing_root_head include_undeclared_aggregate median_field multi_target_options include_entity_head
  ].freeze

  def call(domain_ir)
    customer = domain_ir[:aggregates].find { |aggregate| aggregate[:name] == "Customer" }
    entity = domain_ir[:aggregates].flat_map { |aggregate| aggregate[:entities] }.first
    customer[:queries].push(*gap_queries)
    customer[:commands].push(*gap_commands)
    customer[:ports] = Array(customer[:ports]) + [port("Gateway", "Ping", [attribute("blob", "Mystery")])]
    domain_ir[:aggregates] << ghost_aggregate(customer, entity)
    domain_ir[:read_models].push(*gap_read_models(entity[:name]))
    domain_ir
  end

  def gap_queries
    [
      query("GapCursor", [active], cursor: { field: "reference" }),
      query("GapIndexHints", [active], index_hints: ["status"]),
      query("GapNoWheres", []),
      query("GapUnknownField", [where_clause("nope", "eq", "\"x\"")]),
      query("GapHop", [where_clause("nope/status", "eq", "\"x\"")]),
      query("GapNoneInState", [where_clause("status", "none_in_state", "\"x\"")]),
      query("GapOrderedString", [where_clause("status", "gt", "\"x\"")]),
      query("GapOrderBy", [active], order_by: { field: "nope", direction: "asc" }),
      query("GapLimit", [active], limit: { value: "lots" }),
      query("GapOffset", [active], offset: { value: "lots" }),
      query("GapTenant", [active], authorization: { policy: "OwnRecords", tenant: "nope" })
    ]
  end

  def gap_commands
    [
      command("GapFrobnicate", [mutation("status", "frobnicate", argument("status"))]),
      command("GapStateSource", [mutation("name", "set", { kind: "state", name: "nope" })]),
      command("GapLiteral", [mutation("name", "set", literal(42))]),
      command("GapArithmetic", [mutation("name", "increment", argument("amount"), sign: "+")], [attribute("amount", "Integer")]),
      command("GapClamp", [mutation("name", "clamp", literal([1, 2]))]),
      command("GapBridge", [mutation("name", "set", argument("emails"))], [attribute("emails", "EmailAddress", list: true)]),
      command("GapRemove", [mutation("name", "remove", argument("name"))], [attribute("name", "PersonName")]),
      command("GapReverses", [mutation("CustomerRegistered", "corrects", literal({ reverses: true }))])
    ]
  end

  # A bare, non-list entity-typed attribute: the whole aggregate is skipped
  # (`attribute_type`) and everything it owns cascades (`owning_aggregate`).
  def ghost_aggregate(customer, donor_entity)
    note = deep_copy(donor_entity).merge(name: "Note", commands: [command("Scribble", [])], queries: [], entities: [])
    deep_copy(customer).merge(
      name:       "Ghost",
      attributes: customer[:attributes] + [attribute("note", "Note")],
      commands:   [command("Haunt", [])],
      entities:   [note],
      queries:    [],
      ports:      [port("Line", "Call", [])]
    )
  end

  # `entity_name`: a nested entity a real, generated aggregate declares.
  def gap_read_models(entity_name)
    [
      read_model("GapCursorReport", [head("Account", "accounts")], cursor: { field: "number" }),
      read_model("GapGroupBy", [head("Account", "accounts"), head("Transfer", "transfers")], group_by: [{ field: "status" }]),
      read_model("GapMissingRoot", [head("Account", "accounts")], reference_name: "customer", reference_target: "Customer"),
      read_model("GapUndeclared", [head("Nowhere", "nowheres")]),
      read_model("GapMedian", [head("Account", "accounts")], median_field: "nope"),
      read_model("GapMultiTarget", [head("Account", "accounts"), head("Transfer", "transfers")],
                 wheres: [where_clause("status", "eq", "\"open\"")]),
      read_model("GapHeadHop", [head("Account", "accounts")], wheres: [where_clause("nope/status", "eq", "\"x\"")]),
      read_model("GapEntityHead", [head(entity_name, "entries")], wheres: [where_clause("status", "eq", "\"x\"")])
    ]
  end

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
