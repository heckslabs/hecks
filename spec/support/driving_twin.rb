require "json"
require_relative "kernel_twin"
require_relative "engine_choice"

# Drives pizzas through each driving adapter on one engine, for the twin specs of the driving
# adapters. Each leg runs to its end before the next boots, since a boot with the facade installs
# the `Pizzas` constants for the whole process.
module DrivingTwin
  PIZZAS = File.expand_path("../../examples/pizzas", __dir__)
  PIZZA = { name: { value: "Margherita" }, pizza: { price_cents: { cents: 1200 }, size: { value: "large" } } }.freeze
  CREATE_ARGV = %w[order.create_pizza! name=Margherita pizza.price_cents.cents=1200 pizza.size.value=large].freeze

  # Includes the twin helpers and keeps the storehouse's trace off the owner's cache.
  def self.included(group)
    group.include KernelTwin
    group.include EngineChoice
    group.before { allow(Hecks::Storehouse).to receive(:record!) }
  end

  # @return [Array(Object, Object)] the block's value on the Ruby engine, then on the kernel
  def twin(&) = %i[ruby kernel].map { |engine| driven(engine, &) }

  # @param engine [Symbol] `:ruby` or `:kernel`
  # @yieldparam dispatcher [Object] pizzas booted with the facade; a kernel one is closed after
  # @return [Object] the block's value
  def driven(engine)
    dispatcher = Hecks.boot(PIZZAS, engine: engine)
    yield dispatcher
  ensure
    dispatcher.close if dispatcher.respond_to?(:close)
  end

  # @return [Hash] what the facade answered after a create and one verb on the handle
  def facade_answers
    order = Pizzas::Order.create_pizza!(**PIZZA)
    order.add_topping!(topping: { value: "Basil" }, amount: { value: 3 })
    { order: order.to_h, found: Pizzas::Order.find(order.id).to_h, all: Pizzas::Order.all.map(&:to_h),
      count: Pizzas::Order.count, events: order.events.map(&:name) }
  end

  # @return [Array(String, Integer)] the CLI runner's answer and status
  def cli(runtime, *argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: runtime, argv: argv, program: "hecks run")

  # @return [Hash] the MCP tool's answer for pizzas, without its duration
  def mcp(name, args)
    Hecks::Adapters::Driving::Mcp.answer_tool(name, { "domain" => PIZZAS }.merge(args)).except(:duration_ms)
  end

  # @param engine [String] the `HECKS_ENGINE` the MCP server boots under
  # @param role [String] the role the call states
  # @return [Hash] the MCP dispatch of CreatePizza
  def mcp_create(engine, role: "Chef")
    with_engine(engine)
    mcp("dispatch", "command" => "order.create_pizza", "summary" => "spec", "role" => role,
                    "args" => JSON.parse(JSON.generate(PIZZA)))
  end
end
