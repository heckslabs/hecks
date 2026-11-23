# frozen_string_literal: true

module BakeryDraft
  # What the scripted proposer says of each exchange, by its number, as [kind, statement].
  PROPOSALS = {
    2 => [["thing", "Order"], ["action", "Order: Place -> Placed"], ["thing", "Paperbook"]],
    4 => [["thing", "Loaf"]],
    6 => [["action", "Loaf: Bake -> Baked"], ["rule", "Baking is done before the shop opens"],
          ["work", "Replace the paper book"], ["decision", "Keep phone orders"]]
  }.freeze
end
