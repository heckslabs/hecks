# Hecksagain — Hecks, rewritten with Ruby as the source of truth.
#
# The inversion: the DOMAIN SEMANTICS live in Ruby, and every other target is a
# PROJECTION of them. In Hecks the parser was authored twice — once in Ruby,
# once in Rust — and every drift retired over the last months was a
# disagreement between those two authors. Here there is one author, so there is
# nothing to disagree with.
#
# The DSL surface stays `Hecks.*` so bluebook files read identically. The
# rewrite changes the engine, not the language.
#
#   runtime = Hecks.boot("examples/pizzas")
#   pizza   = runtime.dispatch("Pizzas::Pizza.CreatePizza", name: "Margherita", price_cents: 1200)
#   runtime.dispatch("Pizzas::Pizza.Purchase", id: pizza.id, customer_name: "Chris")
#   runtime.events.last   # => PizzaPurchased(...)

require_relative "hecksagain/naming"
require_relative "hecksagain/aggregate"

require_relative "hecksagain/bluebook/expression/extractor"
require_relative "hecksagain/bluebook/expression/resolver"
require_relative "hecksagain/bluebook/expression/evaluator"

require_relative "hecksagain/bluebook/ir/type_name"
require_relative "hecksagain/bluebook/ir/attribute"
require_relative "hecksagain/bluebook/ir/value_object"
require_relative "hecksagain/bluebook/ir/command"
require_relative "hecksagain/bluebook/ir/aggregate"
require_relative "hecksagain/bluebook/ir/bluebook"
require_relative "hecksagain/bluebook/ir/hexagon"

require_relative "hecksagain/bluebook/dsl/const_shim"
require_relative "hecksagain/bluebook/dsl/attribute_collector"
require_relative "hecksagain/bluebook/dsl/value_object_builder"
require_relative "hecksagain/bluebook/dsl/command_builder"
require_relative "hecksagain/bluebook/dsl/aggregate_builder"
require_relative "hecksagain/bluebook/dsl/bluebook_builder"
require_relative "hecksagain/bluebook/dsl/binding_proxy"
require_relative "hecksagain/bluebook/dsl/hecksagon_builder"
require_relative "hecksagain/bluebook/dsl/port_builder"
require_relative "hecksagain/bluebook/dsl/adapter_builder"
require_relative "hecksagain/bluebook/dsl/world_builder"

require_relative "hecksagain/runtime/event"
require_relative "hecksagain/runtime/value"
require_relative "hecksagain/runtime/instance"
require_relative "hecksagain/runtime/registry"
require_relative "hecksagain/runtime/dispatcher"
require_relative "hecksagain/runtime/loader"

require_relative "hecksagain/adapters/memory"
require_relative "hecksagain/adapters/sqlite"

require_relative "hecksagain/projector/exporter"

module Hecksagain
  VERSION = "2026.07.25.1"

  class LoadOutsideBoot < StandardError; end

  class << self
    attr_reader :current_registry

    # Boot a domain directory and get back the door.
    # `shared:` names the folder holding ports/ and adapters/. Left out, it is
    # found by walking up from the domain.
    def boot(path, shared: nil) = Runtime::Loader.boot(path, shared: shared)

    # Declarations land in whichever registry is booting.
    def with_registry(registry)
      previous          = @current_registry
      @current_registry = registry
      yield
    ensure
      @current_registry = previous
    end

    def bluebook(name, &block)  = collect(:add_bluebook,  Bluebook::DSL::BluebookBuilder.build(name, &block))
    def hecksagon(name, &block) = collect(:add_hecksagon, Bluebook::DSL::HecksagonBuilder.build(name, &block))
    def port(name, &block)    = collect(:add_port,    Bluebook::DSL::PortBuilder.build(name, &block))
    def adapter(name, &block)   = collect(:add_adapter,   Bluebook::DSL::AdapterBuilder.build(name, &block))
    def world(name, &block)     = collect(:add_world,     Bluebook::DSL::WorldBuilder.build(name, &block))

    private

    def collect(method, item)
      unless @current_registry
        raise LoadOutsideBoot,
              "declaration loaded outside a boot — use Hecks.boot(path) rather than requiring the file directly"
      end

      @current_registry.public_send(method, item)
      item
    end
  end
end

# The language keeps its name.
Hecks = Hecksagain
