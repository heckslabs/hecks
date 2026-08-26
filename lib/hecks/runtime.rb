# Hecks::Runtime
#
# The runtime layer's face. `lib/hecks/runtime/` held thirteen files and
# no parent, so the layer had no surface of its own : `lib/hecks.rb`
# required each file by hand, and the runtime's own state — the registry a
# declaration is being collected into — sat on the top-level Hecks module
# beside the DSL words.
#
# What lives here is what RUNS a domain :
#
#   Runtime.boot(path)          load a directory and return its Dispatcher
#   Runtime.with_registry(r)    bind the ambient registry for the duration of a load
#   Runtime.current_registry    the registry a declaration is landing in, or nil
#
# What does NOT live here is what DECLARES one — `Hecks.bluebook`,
# `.hecksagon`, `.port`, `.adapter`, `.world` are loading words and stay on the
# top-level module, which now reads as a facade over this.
#
#   runtime = Hecks::Runtime.boot("examples/pizzas/bluebook")
#   runtime.dispatch("Pizzas::Pizza.CreatePizza", name: "Margherita")
#
# NOTE, and it is the reason this file exists : `current_registry` is still
# process-global. Each boot builds a fresh Registry, and `Loader.bind_runtime`
# installs a fresh facade door whose modules close over THAT boot's dispatcher
# — no class-level runtime binding remains, so two boots in one process no
# longer share dispatch state, only the top-level NAME (the last-bound door
# wins the constant, which is what per-boot install means). Owning the state
# here was the first move ; the dispatcher reachable per-runtime rather than
# through a constant was the second, and it is done — the door is the only
# constant left, and it is a projection, not the runtime.

require_relative "runtime/event"
require_relative "runtime/value"
require_relative "runtime/identity"
require_relative "runtime/instance"
require_relative "runtime/registry"
require_relative "runtime/capability_graph"
require_relative "runtime/errors"
require_relative "runtime/refusal_wording"
require_relative "runtime/caller"
require_relative "runtime/routing"
require_relative "runtime/command_rules"
require_relative "runtime/dependency_planning"
require_relative "runtime/command_interpreter"
require_relative "runtime/port_operation_interpreter"
require_relative "runtime/entity_interpreter"
require_relative "runtime/query_interpreter"
require_relative "runtime/read_model_interpreter"
require_relative "runtime/policy_interpreter"
require_relative "runtime/saga_interpreter"
require_relative "runtime/dispatcher"
require_relative "runtime/rebuild_sweep"
require_relative "runtime/tenant_check"
require_relative "runtime/loader"

module Hecks
  module Runtime
    class << self
      # The registry declarations are currently landing in, or nil outside a
      # boot. Read by the DSL collectors on the top-level module and by the
      # extraction port.
      attr_reader :current_registry

      # Load a bluebook directory and return the Dispatcher bound to it.
      # `install_facade:`, `environment:` — see Loader.boot.
      def boot(path, shared: nil, install_facade: true, environment: nil)
        Loader.boot(path, shared: shared, install_facade: install_facade, environment: environment)
      end

      # `paths` form — see Loader.boot_files.
      def boot_files(paths, shared: nil, install_facade: true, environment: nil)
        Loader.boot_files(paths, shared: shared, install_facade: install_facade, environment: environment)
      end

      # Bind the ambient registry for the duration of the block, restoring
      # whatever was there before. Nesting is safe ; a raise still restores.
      def with_registry(registry)
        previous          = @current_registry
        @current_registry = registry
        yield
      ensure
        @current_registry = previous
      end

      # Bind the ambient caller (see Runtime::Caller) for the duration of
      # the block — who a command's declared `role`, if any, is checked
      # against.
      def as_caller(role:, actor_id: nil, &block) = Caller.as(role: role, actor_id: actor_id, &block)
    end
  end
end
