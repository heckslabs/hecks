require "json"

# A finite instruction language. Program data contain no Ruby callbacks.
# Expressions are tagged trees; the interpreter below is the entire evaluator.
module RelationshipMachine
  module_function

  def copy(value) = JSON.parse(JSON.generate(value))

  def value(expr, ctx)
    case expr.fetch(0)
    when "const" then copy(expr.fetch(1))
    when "arg" then expr.drop(1).reduce(ctx.fetch(:args)) { |x, k| x.fetch(k) }
    when "field" then expr.drop(1).reduce(ctx.fetch(:candidate)) { |x, k| x.fetch(k) }
    when "nonempty" then !value(expr.fetch(1), ctx).empty?
    when "gte" then value(expr.fetch(1), ctx) >= value(expr.fetch(2), ctx)
    when "object" then expr.fetch(1).transform_values { |sub| value(sub, ctx) }
    else raise "unknown expression #{expr.inspect}"
    end
  end

  def execute(program, ctx)
    program.each do |op, *parts|
      break if ctx[:refusal]
      case op
      when "require"
        ctx[:refusal] = parts.fetch(1) unless value(parts.fetch(0), ctx)
      when "put"
        ctx[:candidate][parts.fetch(0)] = copy(value(parts.fetch(1), ctx))
      when "append"
        ctx[:candidate].fetch(parts.fetch(0)) << copy(value(parts.fetch(1), ctx))
      when "event"
        ctx[:pending] << { "name" => parts.fetch(0), "aggregate" => "Pizzas::Order",
                           "id" => ctx.fetch(:id), "payload" => copy(ctx.fetch(:args)) }
      when "commit"
        ctx.fetch(:world).fetch(:instances)["Pizzas::Order##{ctx.fetch(:id)}"] = copy(ctx.fetch(:candidate))
        ctx.fetch(:world).fetch(:events).concat(ctx.fetch(:pending))
        ctx[:pending].clear
      else raise "unknown instruction #{op.inspect}"
      end
    end
  end
end

# Explicit lowering for only these three Pizza commands. It is not a general
# Bluebook compiler and does not infer the programs from fixture expectations.
PROGRAMS = {
  "CreatePizza" => [
    ["put", "name", ["arg", "name"]],
    ["put", "pizza", ["arg", "pizza"]],
    ["put", "toppings", ["const", []]],
    ["put", "customer_name", ["const", nil]],
    ["put", "status", ["const", "available"]],
    ["event", "PizzaCreated"], ["commit"]
  ],
  "AddTopping" => [
    ["append", "toppings", ["object", {
      "name" => ["arg", "topping", "value"], "amount" => ["arg", "amount", "value"]
    }]],
    ["event", "ToppingAdded"], ["commit"]
  ],
  "Purchase" => [
    ["require", ["nonempty", ["field", "toppings"]],
     "Purchase refused — a pizza needs at least one topping"],
    ["require", ["gte", ["arg", "amount", "cents"], ["field", "pizza", "price_cents", "cents"]],
     "Purchase refused — the payment covers the price"],
    ["put", "status", ["const", "sold"]],
    ["event", "PizzaPurchased"], ["commit"]
  ]
}.freeze

def lower(verb)
  RelationshipMachine.copy(PROGRAMS.fetch(verb))
end

root = ENV.fetch("HECKS_SOURCE")
names = %w[accepted_pizza_lifecycle given_unmet_leaves_the_record_purchasable]
results = names.map do |name|
  fixture = JSON.parse(File.read(File.join(root, "spec/corpus/semantics/#{name}.json")))
  world = { instances: {}, events: [], refusals: [] }
  fixture.fetch("steps").each do |step|
    verb = step.fetch("verb").split(".").last
    args = step.fetch("args")
    id = args.fetch("name").is_a?(Hash) ? args.fetch("name").fetch("value") : args.fetch("name")
    old = world.fetch(:instances)["Pizzas::Order##{id}"]
    ctx = { world: world, args: args, id: id, candidate: old ? RelationshipMachine.copy(old) : {},
            pending: [], refusal: nil }
    RelationshipMachine.execute(lower(verb), ctx)
    world.fetch(:refusals) << { "verb" => step.fetch("verb"), "error" => ctx[:refusal],
                                "kind" => "GivenNotMet" } if ctx[:refusal]
  end
  actual = { "instances" => world.fetch(:instances), "events" => world.fetch(:events),
             "refusals" => world.fetch(:refusals) }
  { fixture: name, matched: actual == fixture.fetch("expect") }
end
puts JSON.pretty_generate({ instruction_tags: %w[require put append event commit], results: results })
exit(results.all? { |result| result.fetch(:matched) } ? 0 : 1)
