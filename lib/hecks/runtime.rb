# Hecks::Runtime
#
# Boots a domain directory and holds the ambient registry and caller state a boot runs under.
# `current_registry` is process-global; each boot's dispatcher is per-boot.

require_relative "runtime/event"
require_relative "runtime/value"
require_relative "runtime/identity"
require_relative "runtime/instance"
require_relative "runtime/registry"
require_relative "runtime/outbox"
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
  # The runtime layer: boots a domain directory and holds the ambient registry a boot runs under.
  module Runtime
    class << self
      # The registry declarations are currently landing in, or nil outside a boot.
      attr_reader :current_registry

      # Loads a bluebook directory and returns the Dispatcher bound to it. See Loader.boot.
      #
      #   Hecks::Runtime.boot("examples/pizzas/bluebook")
      #     .dispatch("Pizzas::Pizza.CreatePizza", name: "Margherita")
      #
      # @param path [String] path to a domain directory, or a file inside one
      # @param shared [String, nil] a shared-root override
      # @param install_doors [Boolean] whether to install the Ruby facade constants
      # @param install_facade [Boolean, nil] the deprecated spelling of `install_doors`; warns
      # @param environment [String, nil] the environment name for `Adapters::Folder#load_domain`
      # @return [Runtime::Dispatcher, Runtime::RemoteDispatcher] the dispatcher bound
      #   to the booted domain
      def boot(path, shared: nil, install_doors: true, install_facade: nil, environment: Runtime::Loader::FROM_ENV)
        Loader.boot(path, shared: shared, install_doors: install_doors, environment: environment,
          install_facade: install_facade)
      end

      # Loads only the given files of a domain; otherwise like `boot`. See Loader.boot_files.
      #
      # @param paths [String, Array<String>] one or more file paths within the domain
      # @param shared [String, nil] a shared-root override
      # @param install_doors [Boolean] whether to install the Ruby facade constants
      # @param install_facade [Boolean, nil] the deprecated spelling of `install_doors`; warns
      # @param environment [String, nil] the environment name for the selected-file loader
      # @return [Runtime::Dispatcher, Runtime::RemoteDispatcher] the dispatcher bound
      #   to the booted domain
      def boot_files(paths, shared: nil, install_doors: true, install_facade: nil, environment: Runtime::Loader::FROM_ENV)
        Loader.boot_files(paths, shared: shared, install_doors: install_doors, environment: environment,
          install_facade: install_facade)
      end

      # Bind the ambient registry for the duration of the block, restoring
      # whatever was there before. Nesting is safe ; a raise still restores.
      #
      # @param registry [Runtime::Registry] the registry to make current for the block
      # @yield the code that should see `registry` as `current_registry`
      # @return [Object] the block's result
      def with_registry(registry)
        previous          = @current_registry
        @current_registry = registry
        yield
      ensure
        @current_registry = previous
      end

      # Binds the ambient caller (see Runtime::Caller) for the duration of the block.
      # A command's declared `role` is checked against it.
      #
      # @param role [String, Symbol] the role to check the caller against
      # @param actor_id [String, nil] who is calling, checked against a real Governance
      #   `RoleAssignment` when given; string-equality only against `role` when nil
      # @param as_of [Integer, nil] Unix epoch seconds to check a matching `RoleAssignment`'s
      #   own `starts_at` against; unchecked when nil
      # @param scope [String, nil] the scope to check a matching `RoleAssignment`'s own
      #   `scope` against; unchecked when nil
      # @yield the code to run with this caller bound
      # @return [Object] the block's result
      def as_caller(role:, actor_id: nil, as_of: nil, scope: nil, &)
        Caller.as(role: role, actor_id: actor_id, as_of: as_of, scope: scope, &)
      end
    end
  end
end
