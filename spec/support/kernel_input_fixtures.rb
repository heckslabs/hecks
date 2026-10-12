# Small generated-IR fixtures for the kernel-input spec: the shape of a domain's `ir.json`, cut to
# the commands, queries and entities the module reads.
module KernelInputFixtures
  module_function

  # One command or query attribute of the IR.
  def attribute(name, type, default: nil)
    held = { "name" => name, "type" => type }
    default.nil? ? held : held.merge("default" => default)
  end

  def lease_clock
    reap = { "name" => "Reap", "needs" => [{ "fact" => "now" }],
             "attributes" => [attribute("grace", "Grace", default: { "value" => 0 }), attribute("now", "LeaseInstant")] }
    expired = { "name" => "Expired", "needs" => [{ "fact" => "now" }], "attributes" => [attribute("now", "LeaseInstant")] }
    { "name"       => "LeaseClock",
      "aggregates" => [{ "name" => "Lease", "commands" => [reap], "queries" => [expired] }] }
  end

  def nested_pieces
    remark = { "name" => "Remark", "attributes" => [attribute("note", "Note", default: { "text" => "none" })] }
    retitle = { "name" => "Retitle", "attributes" => [attribute("label", "Label", default: { "value" => "untitled" })] }
    card = { "name" => "Card", "commands" => [remark] }
    board = { "name" => "Board", "commands" => [retitle], "entities" => [card] }
    { "name" => "NestedPieces", "aggregates" => [{ "name" => "Workspace", "entities" => [board] }] }
  end

  def pizzas
    place = { "name" => "Place", "attributes" => [attribute("size", "Size")] }
    { "name" => "Pizzas", "aggregates" => [{ "name" => "Order", "commands" => [place] }] }
  end
end
