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
# AFTER the projector registry and its `Target` mixin are both real —
# every target registers itself as it loads, so this require IS the
# installation of them.
require_relative "hecks/projections"
# AFTER `Projector` (dispatches against the `:cli` projection) and
# `Ports::Clock` (fills a staleness rule's `now` at the door) both exist.
require_relative "hecks/facade/cli_door"
require_relative "hecks/facade/cli_runner"
require_relative "hecks/storehouse"
require_relative "hecks/framework"
require_relative "hecks/embryonaut_bluebook"

module Hecks
  class LoadOutsideBoot < StandardError; end

  class << self
    attr_reader :current_registry

    # The loading words below collect into the registry the RUNTIME is
    # holding open ; booting and that ambient state belong to the runtime
    # layer, so this module is their facade and Hecks::Runtime is where
    # they live.
    # `install_facade:` — see Runtime::Loader.boot. Defaults on; a caller
    # that only dispatches by FQN string can skip the global sugar.
    #
    # `environment:` — RECOVERED, not new: this parameter (and the
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
    def boot(path, shared: nil, install_facade: true, environment: nil)
      Runtime.boot(path, shared: shared, install_facade: install_facade, environment: environment)
    end

    # `paths` — an explicit list of files to boot (a `.bluebook`, its
    # `.hecksagon`, optionally a `.world`), loaded in place from wherever
    # they actually live — see Runtime::Loader.boot_files's own header for
    # why this exists beside `boot` rather than as a special case of it.
    def boot_files(paths, shared: nil, install_facade: true, environment: nil)
      Runtime.boot_files(paths, shared: shared, install_facade: install_facade, environment: environment)
    end

    def with_registry(registry, &block) = Runtime.with_registry(registry, &block)

    def current_registry = Runtime.current_registry

    # Bind who is dispatching for the duration of the block — checked
    # against a command's declared `role`, if it has one. Unbound (the
    # default), a command's role stays exactly what it is without this:
    # decoration.
    #
    # `actor_id` is OPTIONAL — a caller naming only a role is checked by
    # string equality against the command's own `role`, exactly as
    # before. A caller that also names WHO it is lets the check run
    # against a real Governance `RoleAssignment` instead, once the
    # command's domain has Governance attached — see
    # `CommandRules::Authorization`'s own header.
    #
    # `as_of` and `scope` are OPTIONAL too, same shape — see
    # `Runtime.as_caller`'s own header for what each does.
    def as_caller(role:, actor_id: nil, as_of: nil, scope: nil, &block)
      Runtime.as_caller(role: role, actor_id: actor_id, as_of: as_of, scope: scope, &block)
    end

    def bluebook(name, version: nil, &block)
      collect(:add_bluebook, Bluebook::DSL::BluebookBuilder.build(name, version: version, &block))
    end

    def hecksagon(name, &block) = collect(:add_hecksagon, Bluebook::DSL::HecksagonBuilder.build(name, &block))
    def port(name, &block) = collect(:add_port, Bluebook::DSL::PortBuilder.build(name, &block))
    def adapter(name, &block)   = collect(:add_adapter, Bluebook::DSL::AdapterBuilder.build(name, &block))
    def world(name, &block)     = collect(:add_world, Bluebook::DSL::WorldBuilder.build(name, &block))

    def data_translation(name, from:, to:, &block)
      collect(:add_translation, Bluebook::DSL::TranslationBuilder.build(name, from: from, to: to, &block))
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
