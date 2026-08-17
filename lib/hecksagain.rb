require_relative "hecksagain/version"
# The closed sets the runtime computes with, generated from
# vocabulary.bluebook. Plain data, required first, because some of
# them are read while a bluebook is still being parsed.
require_relative "hecksagain/vocabulary"
require_relative "hecksagain/rendering"
require_relative "hecksagain/naming"
require_relative "hecksagain/fqn"
require_relative "hecksagain/freezer"
require_relative "hecksagain/construct"
# Before `bluebook` — every construct under `Bluebook` includes or
# extends this to declare what it emits.
require_relative "hecksagain/ir"
require_relative "hecksagain/literal"
require_relative "hecksagain/facade"
require_relative "hecksagain/query_specification"

require_relative "hecksagain/ports"
require_relative "hecksagain/bluebook"
require_relative "hecksagain/router"

require_relative "hecksagain/runtime"
require_relative "hecksagain/translation"
require_relative "hecksagain/adapters"
require_relative "hecksagain/projector"
# AFTER the projector registry and its `Target` mixin are both real —
# every target registers itself as it loads, so this require IS the
# installation of them.
require_relative "hecksagain/projections"
# AFTER `Projector` (dispatches against the `:cli` projection) and
# `Ports::Clock` (fills a staleness rule's `now` at the door) both exist.
require_relative "hecksagain/facade/cli_door"
require_relative "hecksagain/facade/cli_runner"
require_relative "hecksagain/framework"
require_relative "hecksagain/embryonaut_bluebook"

module Hecksagain
  class LoadOutsideBoot < StandardError; end

  class << self
    attr_reader :current_registry

    # The loading words below collect into the registry the RUNTIME is
    # holding open ; booting and that ambient state belong to the runtime
    # layer, so this module is their facade and Hecksagain::Runtime is where
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
    # / #add_world). hecksagain never reads ENV itself — a caller
    # resolves its own env var name and passes the resulting string
    # straight through, e.g. `Hecks.boot(path, environment:
    # ENV.fetch("MYAPP_ENV", "development"))`.
    def boot(path, shared: nil, install_facade: true, environment: nil)
      Runtime.boot(path, shared: shared, install_facade: install_facade, environment: environment)
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
    def as_caller(role:, actor_id: nil, &block) = Runtime.as_caller(role: role, actor_id: actor_id, &block)

    def bluebook(name, version: nil, &block)
      collect(:add_bluebook, Bluebook::DSL::BluebookBuilder.build(name, version: version, &block))
    end

    def hecksagon(name, &block) = collect(:add_hecksagon, Bluebook::DSL::HecksagonBuilder.build(name, &block))
    def port(name, &block) = collect(:add_port, Bluebook::DSL::PortBuilder.build(name, &block))
    def adapter(name, &block)   = collect(:add_adapter,   Bluebook::DSL::AdapterBuilder.build(name, &block))
    def world(name, &block)     = collect(:add_world,     Bluebook::DSL::WorldBuilder.build(name, &block))

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

Hecks = Hecksagain
