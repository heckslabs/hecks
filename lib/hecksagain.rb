
require_relative "hecksagain/rendering"
require_relative "hecksagain/naming"
require_relative "hecksagain/fqn"
require_relative "hecksagain/construct"
require_relative "hecksagain/facade"
require_relative "hecksagain/query_specification/common/specification"
require_relative "hecksagain/query_specification/common/null_policy"
require_relative "hecksagain/query_specification/common/dsl"
require_relative "hecksagain/query_specification/read_model/specification"

require_relative "hecksagain/ports"
require_relative "hecksagain/bluebook"
require_relative "hecksagain/router"

require_relative "hecksagain/runtime"
require_relative "hecksagain/translation/scaffold"
require_relative "hecksagain/translation/audit"
require_relative "hecksagain/translation/reattest"

require_relative "hecksagain/adapters/driven/memory/memory"
require_relative "hecksagain/adapters/driven/sqlite/sqlite"
require_relative "hecksagain/adapters/driven/postgres/postgres"
require_relative "hecksagain/adapters/driven/heki/heki"
require_relative "hecksagain/adapters/driven/prism/prism"
require_relative "hecksagain/adapters/driven/folder/folder"

require_relative "hecksagain/projector/exporter"

module Hecksagain
  VERSION = "2026.07.25.1"

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
