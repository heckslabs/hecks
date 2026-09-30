require_relative "hecks/version"
# The closed sets the runtime computes with, generated from
# vocabulary.bluebook. Plain data, required first, because some of
# them are read while a bluebook is still being parsed.
require_relative "hecks/vocabulary"
require_relative "hecks/rendering"
require_relative "hecks/naming"
require_relative "hecks/fqn"
require_relative "hecks/freezer"
require_relative "hecks/construct"
# Before `bluebook` — every construct under `Bluebook` includes or
# extends this to declare what it emits.
require_relative "hecks/ir"
require_relative "hecks/literal"
require_relative "hecks/facade"
require_relative "hecks/query_specification"

require_relative "hecks/ports"
require_relative "hecks/bluebook"
require_relative "hecks/router"

require_relative "hecks/runtime"
require_relative "hecks/adapters"
require_relative "hecks/projector"
# After the projector registry and its `Target` mixin are both real —
# every target registers itself as it loads, so this require is the
# installation of them.
require_relative "hecks/projections"
# After `Projector` (dispatches against the `:cli` projection) and
# `Ports::Clock` (fills a staleness rule's `now` at the door) both exist.
require_relative "hecks/facade/cli_door"
require_relative "hecks/facade/cli_runner"
require_relative "hecks/storehouse"
require_relative "hecks/mcp_stdio_guard"
require_relative "hecks/mcp_door_scope"
require_relative "hecks/framework"
require_relative "hecks/vendoring"
require_relative "hecks/embryonaut_bluebook"

# The corpus table walks `examples/`, `qa/` and `spec/`, which only a checkout
# has, so it loads on first use.
Hecks.autoload(:Corpus, File.expand_path("hecks/corpus", __dir__))

# The chapters a hecksagon can `attaches` by name (ADR 0080); loads on first use.
Hecks.autoload(:Chapters, File.expand_path("hecks/chapters", __dir__))

# Root namespace and public facade of the DSL/runtime: `Hecks.boot`/`.boot_files`
# assemble a running domain from `.bluebook`/`.hecksagon`/`.world` files.
module Hecks
  class LoadOutsideBoot < StandardError; end

  class << self
    # Boots a domain from `path`, assembling a running dispatcher from its
    # `.bluebook`/`.hecksagon`/`.world` files. hecks never reads ENV itself —
    # a caller resolves its own env var name and passes it as `environment`.
    # @param path [String] path to a domain directory, or a file inside one
    # @param shared [String, nil] a shared-root override; see `Runtime::Loader.boot`
    # @param install_facade [Boolean] install the `Widget::Item.Add`-style facade
    # @param environment [String, nil] env name; its `.hecksagon`/`.world` overlay,
    #   if present, loads after the domain's own
    # @return [Runtime::Dispatcher, Runtime::RemoteDispatcher] dispatcher bound to the domain
    def boot(path, shared: nil, install_facade: true, environment: nil)
      Runtime.boot(path, shared: shared, install_facade: install_facade, environment: environment)
    end

    # Boots a domain from an explicit list of files (a `.bluebook`, its
    # `.hecksagon`, optionally a `.world`) instead of a whole directory —
    # see `Runtime::Loader.boot_files` for why this exists beside `boot`.
    # @param paths [String, Array<String>] one or more file paths within the domain
    # @param shared [String, nil] a shared-root override; see `Runtime::Loader.boot_files`
    # @param install_facade [Boolean] install the `Widget::Item.Add`-style facade
    # @param environment [String, nil] environment name passed to the selected-file loader
    # @return [Runtime::Dispatcher, Runtime::RemoteDispatcher] dispatcher bound to the domain
    def boot_files(paths, shared: nil, install_facade: true, environment: nil)
      Runtime.boot_files(paths, shared: shared, install_facade: install_facade, environment: environment)
    end

    # Binds the ambient registry for the duration of the block.
    #
    # @param registry [Runtime::Registry] the registry to make current for the block
    # @yield the code that should see `registry` as `current_registry`
    # @return [Object] the block's result
    def with_registry(registry, &) = Runtime.with_registry(registry, &)

    # Reads the ambient registry a declaration is currently landing in.
    #
    # @return [Runtime::Registry, nil] the current registry, or nil outside a boot
    def current_registry = Runtime.current_registry

    # Binds who is dispatching for the duration of the block, checked against
    # a command's declared `role`; unbound (the default) is a no-op.
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
      Runtime.as_caller(role: role, actor_id: actor_id, as_of: as_of, scope: scope, &)
    end

    # Declares a chapter — a `.bluebook` file's top-level word.
    #
    # @param name [String] the chapter's declared name
    # @param version [String, nil] the chapter's pinned version, or nil for unversioned
    # @yield the chapter's body, evaluated against a `Bluebook::DSL::BluebookBuilder`
    # @return [Bluebook::Chapter] the built, judged chapter
    # @raise [LoadOutsideBoot] if called outside `Hecks.boot`/`.boot_files`
    # @raise [Bluebook::DSL::Malformed] if the chapter fails the language's own judgment
    def bluebook(name, version: nil, &)
      collect(:add_bluebook, Bluebook::DSL::BluebookBuilder.build(name, version: version, &))
    end

    # Declares a hecksagon — a `.hecksagon` file's top-level word, binding a
    # domain's aggregates to adapters.
    #
    # @param name [String, Symbol] the domain's name the hecksagon binds
    # @yield the hecksagon's body, evaluated against a `Bluebook::DSL::HecksagonBuilder`
    # @return [Bluebook::Hecksagon] the built hecksagon
    # @raise [LoadOutsideBoot] if called outside `Hecks.boot`/`.boot_files`
    def hecksagon(name, &) = collect(:add_hecksagon, Bluebook::DSL::HecksagonBuilder.build(name, &))

    # Declares a port — a `.port` file's top-level word.
    #
    # `legacy_bare_port: true` — only this entry point allows a completely
    # empty port body; see `DomainPortBuilder#initialize`'s own doc.
    #
    # @param name [String] the port's name
    # @yield the port's body, evaluated against a `Bluebook::DSL::DomainPortBuilder`
    # @return [Bluebook::Port, Bluebook::DomainPort] the built port
    # @raise [LoadOutsideBoot] if called outside `Hecks.boot`/`.boot_files`
    def port(name, &) = collect(:add_port, Bluebook::DSL::DomainPortBuilder.build(name, legacy_bare_port: true, &))

    # Declares an adapter — an `.adapter` file's top-level word.
    #
    # @param name [String] the adapter's name
    # @yield the adapter's body, evaluated against a `Bluebook::DSL::AdapterBuilder`
    # @return [Bluebook::Adapter] the built, judged adapter
    # @raise [LoadOutsideBoot] if called outside `Hecks.boot`/`.boot_files`
    def adapter(name, &)   = collect(:add_adapter, Bluebook::DSL::AdapterBuilder.build(name, &))

    # Declares a world — a `.world` file's top-level word, naming a domain's
    # deployment realm.
    #
    # @param name [String, Symbol] the domain's name the world describes
    # @yield the world's body, evaluated against a `Bluebook::DSL::WorldBuilder`
    # @return [Bluebook::World] the built, judged world
    # @raise [LoadOutsideBoot] if called outside `Hecks.boot`/`.boot_files`
    def world(name, &)     = collect(:add_world, Bluebook::DSL::WorldBuilder.build(name, &))

    # Declares a data translation — a `.translation` file's top-level word,
    # migrating one domain's stored shape from one era to the next.
    #
    # @param name [String, Symbol] the domain this translation carries forward
    # @param from [String, Symbol] the origin era
    # @param to [String, Symbol] the destination era
    # @yield the translation's body, evaluated against a
    #   `Bluebook::DSL::TranslationBuilder`
    # @return [Bluebook::Translation] the built, judged translation
    # @raise [LoadOutsideBoot] if called outside `Hecks.boot`/`.boot_files`
    # @raise [Bluebook::DSL::Malformed] if `name`, `from`, or `to` is empty
    def data_translation(name, from:, to:, &)
      collect(:add_translation, Bluebook::DSL::TranslationBuilder.build(name, from: from, to: to, &))
    end

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
