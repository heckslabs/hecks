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

require_relative "hecksagain/language/expression/extractor"
require_relative "hecksagain/language/expression/resolver"
require_relative "hecksagain/language/expression/evaluator"

require_relative "hecksagain/language/ir/type_name"
require_relative "hecksagain/language/ir/attribute"
require_relative "hecksagain/language/ir/value_object"
require_relative "hecksagain/language/ir/command"
require_relative "hecksagain/language/ir/aggregate"
require_relative "hecksagain/language/ir/bluebook"
require_relative "hecksagain/language/ir/hexagon"

require_relative "hecksagain/language/dsl/const_shim"
require_relative "hecksagain/language/dsl/attribute_collector"
require_relative "hecksagain/language/dsl/value_object_builder"
require_relative "hecksagain/language/dsl/command_builder"
require_relative "hecksagain/language/dsl/aggregate_builder"
require_relative "hecksagain/language/dsl/bluebook_builder"
require_relative "hecksagain/language/dsl/binding_proxy"
require_relative "hecksagain/language/dsl/hecksagon_builder"
require_relative "hecksagain/language/dsl/family_builder"
require_relative "hecksagain/language/dsl/adapter_builder"
require_relative "hecksagain/language/dsl/world_builder"

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
    # `boundary:` names the folder holding the shared families and adapters.
    # Left out, it is found by walking up from the domain.
    def boot(path, boundary: nil) = Runtime::Loader.boot(path, boundary: boundary)

    # Declarations land in whichever registry is booting.
    def with_registry(registry)
      previous          = @current_registry
      @current_registry = registry
      yield
    ensure
      @current_registry = previous
    end

    def bluebook(name, &block)  = collect(:add_bluebook,  Language::DSL::BluebookBuilder.build(name, &block))
    def hecksagon(name, &block) = collect(:add_hecksagon, Language::DSL::HecksagonBuilder.build(name, &block))
    def family(name, &block)    = collect(:add_family,    Language::DSL::FamilyBuilder.build(name, &block))
    def adapter(name, &block)   = collect(:add_adapter,   Language::DSL::AdapterBuilder.build(name, &block))
    def world(name, &block)     = collect(:add_world,     Language::DSL::WorldBuilder.build(name, &block))

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
