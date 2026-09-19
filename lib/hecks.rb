require_relative "hecks/version"
require_relative "hecks/deprecation"
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
require_relative "hecks/framework"
require_relative "hecks/corpus"
require_relative "hecks/embryonaut_bluebook"

# The root namespace and public facade of the whole DSL/runtime: `Hecks.boot`/
# `.boot_files` assemble a running domain from `.bluebook`/`.hecksagon`/
# `.world` files, and `.bluebook`/`.hecksagon`/`.port`/`.adapter`/`.world`/
# `.data_translation` are the top-level declaration words every such file
# opens with, each collecting its built construct into the currently booting
# Registry (`#collect`, private below).
module Hecks
  class LoadOutsideBoot < StandardError; end

  class << self
    # The loading words below collect into the registry the runtime is
    # holding open ; booting and that ambient state belong to the runtime
    # layer, so this module is their facade and Hecks::Runtime is where
    # they live.
    # `install_facade:` — see Runtime::Loader.boot. Defaults on; a caller
    # that only dispatches by FQN string can skip the global sugar.
    #
    # `environment:` — recovered, not new: this parameter (and the
    # `environments/<name>.hecksagon` / `.world` overlay it loads —
    # see Adapters::Folder#load_domain) existed on a prior commit of
    # this repo (933d1dd), was vendored out to a real consumer
    # (lifeadelics/domain), and was then lost from this repo's own
    # history (no branch here reaches that commit). Ported forward
    # from the consumer's vendor snapshot — the only surviving copy —
    # and generalized: the original only loaded a `.hecksagon`
    # overlay; this also loads a same-named `.world` overlay, both
    # merged into the base rather than replacing it (Registry#add_hecksagon
    # / #add_world). hecks never reads ENV itself — a caller
    # resolves its own env var name and passes the resulting string
    # straight through, e.g. `Hecks.boot(path, environment:
    # ENV.fetch("MYAPP_ENV", "development"))`.
    #
    # @param path [String] path to a domain directory, or a file inside one
    # @param shared [String, nil] a shared-root override; see `Runtime::Loader.boot`
    # @param install_facade [Boolean] whether to install the `Widget::Item.Add`-style
    #   Ruby facade constants for this boot
    # @param environment [String, nil] the environment name whose
    #   `environments/<name>.hecksagon`/`.world` overlay, if present, loads after the
    #   domain's own
    # @return [Runtime::Dispatcher, Runtime::RemoteDispatcher] the dispatcher bound
    #   to the booted domain
    def boot(path, shared: nil, install_facade: true, environment: nil)
      Runtime.boot(path, shared: shared, install_facade: install_facade, environment: environment)
    end

    # `paths` — an explicit list of files to boot (a `.bluebook`, its
    # `.hecksagon`, optionally a `.world`), loaded in place from wherever
    # they actually live — see Runtime::Loader.boot_files's own header for
    # why this exists beside `boot` rather than as a special case of it.
    #
    # @param paths [String, Array<String>] one or more file paths within the domain
    #   to load, instead of the whole directory
    # @param shared [String, nil] a shared-root override; see `Runtime::Loader.boot_files`
    # @param install_facade [Boolean] whether to install the `Widget::Item.Add`-style
    #   Ruby facade constants for this boot
    # @param environment [String, nil] the environment name passed through to the
    #   selected-file loader
    # @return [Runtime::Dispatcher, Runtime::RemoteDispatcher] the dispatcher bound
    #   to the booted domain
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

    # Bind who is dispatching for the duration of the block — checked
    # against a command's declared `role`, if it has one. Unbound (the
    # default), a command's role stays exactly what it is without this:
    # decoration.
    #
    # `actor_id` is optional — a caller naming only a role is checked by
    # string equality against the command's own `role`, exactly as
    # before. A caller that also names who it is lets the check run
    # against a real Governance `RoleAssignment` instead, once the
    # command's domain has Governance attached — see
    # `CommandRules::Authorization`'s own header.
    #
    # `as_of` and `scope` are optional too, same shape — see
    # `Runtime.as_caller`'s own header for what each does.
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
    # Repointed to DomainPortBuilder — the migration DomainPort's own
    # class comment names as its goal, now landed for the top-level
    # `.port` file callers too (the aggregate-scoped `Thing.port(...)`,
    # binding_proxy.rb, already went through this builder). Every real
    # `.port` file only ever spells `verb`/`signal` (no `.port` file
    # declares operations — that's DomainPort's own newer shape), and
    # DomainPortBuilder's own bare-verb branch produces the exact same
    # `Port` object PortBuilder itself did (dsl_spec.rb's own byte-
    # identity check) — a pure repoint, no behavior change for any
    # existing caller reading `.verb`/`.signal` off what comes back.
    #
    # `legacy_bare_port: true` — the one real semantic gap this repoint
    # would otherwise open: `PortBuilder#build` never refused a
    # completely empty build (no verb, no signal even), a real shape
    # dsl_spec.rb's own "a port" tests exercise (`signal`-only, no
    # `verb`). `DomainPortBuilder`'s own "declares no verb and no
    # operations" refusal is real and correct for its other two callers
    # (`BindingProxy#port`, `HecksagonBuilder#port_impl`) — only this,
    # the literal top-level `.port` file entry point, keeps the older,
    # looser rule (see `DomainPortBuilder#initialize`'s own comment).
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
