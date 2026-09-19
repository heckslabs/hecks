# **Every skip family, planted** — the corpus generates everything today, so
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

  # Plants one ungeneratable gap per construct family into `domain_ir`, mutating it in place.
  #
  # @param domain_ir [Hash] the parsed domain IR, holding `:aggregates` and `:read_models` keys
  # @return [Hash] the same `domain_ir`, now carrying the added gap queries, commands, a ports
  #   entry, a ghost aggregate, and gap read models
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

  # Builds the query gaps, one per query-construct family.
  #
  # @return [Array<Hash>] one query-gap literal per query-construct family
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

  # Builds the command gaps, one per command-construct family.
  #
  # @return [Array<Hash>] one command-gap literal per command-construct family
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

  # Builds a "Ghost" aggregate carrying a nested "Note" entity, planting an
  # attribute-type/owning-aggregate gap pair.
  #
  # A bare, non-list entity-typed attribute: the whole aggregate is skipped
  # (`attribute_type`) and everything it owns cascades (`owning_aggregate`).
  #
  # @param customer [Hash] the domain IR's `Customer` aggregate hash, copied as the base
  # @param donor_entity [Hash] an existing aggregate's entity hash, copied and renamed to `"Note"`
  # @return [Hash] the new `Ghost` aggregate hash, ready to append to `domain_ir[:aggregates]`
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

  # Builds one read-model gap per read-model-construct family.
  #
  # @param entity_name [String] name of a nested entity a real, generated aggregate declares
  # @return [Array<Hash>] one read-model-gap literal per construct family
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

  # Builds the shared `"status" eq "active"` where-clause the query gaps reuse.
  #
  # @return [Hash] a where-clause literal matching `status` `eq` `"active"`
  def active = where_clause("status", "eq", "\"active\"")

  # Builds a where-clause IR literal.
  #
  # @param field [String] attribute or reference-hop path the clause filters on
  # @param operator [String] comparison operator name, such as `"eq"` or `"gt"`
  # @param value [String] IR literal-value source text, already quoted for string literals
  # @return [Hash] a where-clause literal with `:field`, `:op`, `:value` keys
  def where_clause(field, operator, value) = { field: field, op: operator, value: value }

  # Builds a mutation IR literal.
  #
  # @param target [String] name of the attribute or event the mutation targets
  # @param operator [String] mutation operator name, such as `"set"` or `"increment"`
  # @param source [Hash] value-source literal, from `#argument` or `#literal`
  # @param sign [String] arithmetic sign for `"increment"`/`"decrement"` operators, `""` otherwise
  # @return [Hash] a mutation literal with `:target`, `:op`, `:sign`, `:source` keys
  def mutation(target, operator, source, sign: "") = { target: target, op: operator, sign: sign, source: source }

  # Builds an argument-source IR literal.
  #
  # @param name [String] name of the attribute the argument reads
  # @return [Hash] an argument-source literal with `:kind` `"argument"` and `:name`
  def argument(name) = { kind: "argument", name: name }

  # Builds a literal-source IR literal.
  #
  # @param value [Object] the literal value to embed, as the IR would carry it
  # @return [Hash] a literal-source literal with `:kind` `"literal"` and `:value`
  def literal(value) = { kind: "literal", value: value }

  # Builds an aggregate-head IR literal for a read model.
  #
  # @param aggregate [String] name of the aggregate the read model heads on
  # @param as_name [String] alias the read model uses for this head
  # @return [Hash] an aggregate-head literal with `:aggregate`, `:as`, and `:many` set `true`
  def head(aggregate, as_name) = { aggregate: aggregate, as: as_name, many: true }

  # Builds a port IR literal with a single operation.
  #
  # @param name [String] name of the port
  # @param operation [String] name of the single operation the port declares
  # @param attributes [Array<Hash>] attribute literals from `#attribute`, the operation's arguments
  # @return [Hash] a port literal with `:name` and one `:operations` entry, `:emits` empty
  def port(name, operation, attributes) = { name: name, operations: [{ name: operation, attributes: attributes, emits: [] }] }

  # Copies an IR fragment so a gap builder can mutate it without touching the original.
  #
  # @param value [Object] any Marshal-able IR fragment
  # @return [Object] an independent deep copy of `value`
  def deep_copy(value) = Marshal.load(Marshal.dump(value))

  # Builds a query IR literal, defaulting every key `#gap_queries` does not override.
  #
  # @param name [String] name of the query
  # @param wheres [Array<Hash>] where-clause literals from `#where_clause`
  # @param options [Hash] overrides merged over the defaults, such as `:cursor`, `:order_by`,
  #   `:limit`, `:offset`, `:index_hints`, `:authorization`
  # @return [Hash] a query literal with `:name`, `:description` `nil`, `:attributes` empty,
  #   `:wheres`, `:order_by` `nil`, `:limit` `nil`, plus any `options`
  def query(name, wheres, **options)
    { name: name, description: nil, attributes: [], wheres: wheres, order_by: nil, limit: nil }.merge(options)
  end

  # Builds a command IR literal, defaulting every key `#gap_commands` does not override.
  #
  # @param name [String] name of the command
  # @param mutations [Array<Hash>] mutation literals from `#mutation`
  # @param attributes [Array<Hash>] attribute literals from `#attribute` the command accepts
  # @return [Hash] a command literal with `:name`, `:mutations`, `:attributes`, and every other
  #   IR key defaulted to `nil` or `[]`
  def command(name, mutations, attributes = [])
    { name: name, role: nil, goal: nil, references: nil, attributes: attributes, givens: [], ensures: [],
      mutations: mutations, emits: [], from: nil, provenance: nil }
  end

  # Builds a read-model IR literal, defaulting every key `#gap_read_models` does not override.
  #
  # @param name [String] name of the read model
  # @param heads [Array<Hash>] aggregate-head literals from `#head`
  # @param options [Hash] overrides merged over the defaults, such as `:cursor`, `:group_by`,
  #   `:wheres`, `:median_field`, `:reference_name`, `:reference_target`
  # @return [Hash] a read-model literal with `:name`, `:query_name` (`name` downcased),
  #   `:aggregate_heads`, plus any `options`
  def read_model(name, heads, **options)
    { name: name, description: nil, reference_name: nil, reference_target: nil, query_name: name.downcase,
      wheres: [], order_by: nil, limit: nil, aggregate_heads: heads, group_by: [] }.merge(options)
  end

  # Builds an attribute IR literal, defaulting every option key it is not given.
  #
  # @param name [String] name of the attribute
  # @param type [String] IR type name, such as `"PersonName"` or an entity name
  # @param list [Boolean] whether the attribute is a list of `type`
  # @return [Hash] an attribute literal with `:name`, `:type`, `:list`, and every other
  #   attribute-option key defaulted to `nil`/`false`
  def attribute(name, type, list: false)
    { name: name, type: type, list: list, default: nil, optional: false, pattern: nil, admits: nil, relationship: nil }
  end
end
