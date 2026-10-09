require_relative "ir_builders"

# Plants one ungeneratable construct per skip family into a copy of banking's IR,
# so the planted-gaps spec freezes hecks-codegen's `construct` choices for each.
module ManifestGapFamilies
  extend ManifestIrBuilders

  module_function

  # Every construct `call` plants; the spec checks each lands in the manifest.
  CONSTRUCTS = %w[
    attribute_type owning_aggregate
    cursor index_hints no_wheres where_unrecognized_field reference_hop_where where_none_in_state where_literal
    order_by limit offset authorization
    mutation_op state_source set_literal port_attribute_type
    arithmetic clamp set_argument_bridge remove_field corrects_reverses
    group_by missing_root_head include_undeclared_aggregate median_field include_entity_head
  ].freeze

  # Mutates `domain_ir` in place, adding one gap per construct family; returns it.
  def call(domain_ir)
    customer = domain_ir[:aggregates].find { |aggregate| aggregate[:name] == "Customer" }
    entity = domain_ir[:aggregates].flat_map { |aggregate| aggregate[:entities] }.first
    plant_customer_gaps(customer)
    domain_ir[:aggregates] << ghost_aggregate(customer, entity)
    domain_ir[:read_models].push(*gap_read_models(entity[:name]))
    domain_ir
  end

  def plant_customer_gaps(customer)
    customer[:queries].push(*gap_queries)
    customer[:commands].push(*gap_commands)
    customer[:ports] = Array(customer[:ports]) + [port("Gateway", "Ping", [attribute("blob", "Mystery")])]
  end

  def gap_queries = query_shape_gaps + where_gaps + query_option_gaps

  def query_shape_gaps
    [
      query("GapCursor", [active], cursor: { field: "reference" }),
      query("GapIndexHints", [active], index_hints: ["status"]),
      query("GapNoWheres", [], attributes: [attribute("name", "String")])
    ]
  end

  def where_gaps
    [
      query("GapUnknownField", [where_clause("nope", "eq", "\"x\"")]),
      query("GapHop", [where_clause("nope/status", "eq", "\"x\"")]),
      query("GapNoneInState", [where_clause("status", "none_in_state", "\"x\"")]),
      query("GapOrderedString", [where_clause("status", "gt", "\"x\"")])
    ]
  end

  def query_option_gaps
    [
      query("GapOrderBy", [active], order_by: { field: "nope", direction: "asc" }),
      query("GapLimit", [active], limit: { value: "lots" }),
      query("GapOffset", [active], offset: { value: "lots" }),
      query("GapTenant", [active], authorization: { policy: "OwnRecords", tenant: "nope" })
    ]
  end

  def gap_commands = mutation_source_gaps + mutation_operator_gaps + mutation_target_gaps

  def mutation_source_gaps
    [
      command("GapFrobnicate", [mutation("status", "frobnicate", argument("status"))]),
      command("GapStateSource", [mutation("name", "set", { kind: "state", name: "nope" })]),
      command("GapLiteral", [mutation("name", "set", literal(42))])
    ]
  end

  def mutation_operator_gaps
    [
      command("GapArithmetic", [mutation("name", "increment", argument("amount"), sign: "+")], [attribute("amount", "Integer")]),
      command("GapClamp", [mutation("name", "clamp", literal([1, 2]))]),
      command("GapBridge", [mutation("name", "set", argument("emails"))], [attribute("emails", "EmailAddress", list: true)])
    ]
  end

  def mutation_target_gaps
    [
      command("GapRemove", [mutation("name", "remove", argument("name"))], [attribute("name", "PersonName")]),
      command("GapReverses", [mutation("CustomerRegistered", "corrects", literal({ reverses: true }))])
    ]
  end

  # A bare, non-list entity-typed attribute skips the whole aggregate (`attribute_type`)
  # and cascades to everything it owns (`owning_aggregate`).
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

  def gap_read_models(entity_name)
    [
      read_model("GapCursorReport", [head("Account", "accounts")], cursor: { field: "number" }),
      read_model("GapGroupBy", [head("Account", "accounts"), head("Transfer", "transfers")], group_by: [{ field: "status" }]),
      read_model("GapMissingRoot", [head("Account", "accounts")], reference_name: "customer", reference_target: "Customer"),
      read_model("GapUndeclared", [head("Nowhere", "nowheres")]),
      read_model("GapMedian", [head("Account", "accounts")], median_field: "nope"),
      read_model("GapHeadHop", [head("Account", "accounts")], wheres: [where_clause("nope/status", "eq", "\"x\"")]),
      read_model("GapEntityHead", [head(entity_name, "entries")], wheres: [where_clause("status", "eq", "\"x\"")])
    ]
  end
end
