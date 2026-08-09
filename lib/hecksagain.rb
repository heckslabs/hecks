
require_relative "hecksagain/version"
require_relative "hecksagain/rendering"
require_relative "hecksagain/naming"
require_relative "hecksagain/fqn"
require_relative "hecksagain/construct"
require_relative "hecksagain/facade"
require_relative "hecksagain/query_specification"

require_relative "hecksagain/ports"
require_relative "hecksagain/bluebook"
require_relative "hecksagain/router"

require_relative "hecksagain/runtime"
require_relative "hecksagain/translation"
require_relative "hecksagain/adapters"
require_relative "hecksagain/projector"
require_relative "hecksagain/framework"

module Hecksagain
  class LoadOutsideBoot < StandardError; end

  class << self
    attr_reader :current_registry

    # The loading words below collect into the registry the RUNTIME is
    # holding open ; booting and that ambient state belong to the runtime
    # layer, so this module is their facade and Hecksagain::Runtime is where
    # they live.
    def boot(path, shared: nil) = Runtime.boot(path, shared: shared)

    def with_registry(registry, &block) = Runtime.with_registry(registry, &block)

    def current_registry = Runtime.current_registry

    # Bind who is dispatching for the duration of the block — checked
    # against a command's declared `role`, if it has one. Unbound (the
    # default), a command's role stays exactly what it is without this:
    # decoration.
    def as_caller(role:, &block) = Runtime.as_caller(role: role, &block)

    def bluebook(name, version: nil, &block) = collect(:add_bluebook, Bluebook::DSL::BluebookBuilder.build(name, version: version, &block))
    def hecksagon(name, &block) = collect(:add_hecksagon, Bluebook::DSL::HecksagonBuilder.build(name, &block))
    def port(name, &block)    = collect(:add_port,    Bluebook::DSL::PortBuilder.build(name, &block))
    def adapter(name, &block)   = collect(:add_adapter,   Bluebook::DSL::AdapterBuilder.build(name, &block))
    def world(name, &block)     = collect(:add_world,     Bluebook::DSL::WorldBuilder.build(name, &block))
    def data_translation(name, from:, to:, &block) = collect(:add_translation, Bluebook::DSL::TranslationBuilder.build(name, from: from, to: to, &block))

    private

    def collect(method, item)
      unless Runtime.current_registry
        raise LoadOutsideBoot,
              "declaration loaded outside a boot — use Hecks.boot(path) rather than requiring the file directly"
      end

      Runtime.current_registry.public_send(method, item)
      item
    end
  end
end

Hecks = Hecksagain
