require_relative "registry/verification"
require_relative "registry/saga_persistence"
require_relative "registry/world_defaults"
require_relative "outbox"
require_relative "../naming"

module Hecks
  module Runtime
    # Raised when a registry can't resolve required wiring: an unbound aggregate, an
    # unknown adapter, or a port/adapter mismatch.
    class WiringError < StandardError; end

    # The collections a boot gathers: bluebooks, hecksagons, ports, adapters, worlds, and logs.
    # Wiring verification, saga persistence, and world defaults live under registry/.
    class Registry
      include Verification
      include SagaPersistence
      include WorldDefaults

      # The thread-local key under which open reaction collections are kept.
      REACTION_SINKS = :hecks_reaction_sinks

      attr_reader :root, :bluebooks, :hecksagons, :ports, :adapters, :worlds, :event_log,
                  :reaction_log, :saga_log, :saga_instances, :translations, :saga_mutex,
                  :saga_dispatch_log, :policy_dispatch_log, :bluebook_sources,
                  :pending_privacy_markings

      # @param root [String, nil] the booting project's root directory, the base
      #   a shared ports/adapters root and a `.world`'s own relative paths resolve
      #   against; nil for a registry with no such root
      def initialize(root: nil)
        @root         = root
        @bluebooks    = {}
        @bluebook_sources = {}
        @hecksagons = {}
        @bounded_chapters = {}
        @ports = {}
        @adapters     = {}
        @worlds       = {}
        @translations = []
        @event_log    = []
        @reaction_log = []
        @saga_log = []
        # Recorded at hecksagon-build time (AggregateDoor#mark_sensitive); Loader.boot's
        # post-dispatch step turns each entry into a real Privacy::Marking.Mark, idempotently.
        @pending_privacy_markings = []
        # Ruby-only; unlike saga_log/reaction_log (ported byte-for-byte to
        # rust/src/kernel/orchestrate.rs, per spec/rust_conformance_spec.rb), these carry
        # the raw dispatch-binding inputs Properties.dispatch_binding_fidelity re-derives.
        @saga_dispatch_log   = []
        @policy_dispatch_log = []
        @saga_instances = Hash.new { |h, k| h[k] = {} }
        # Guards saga_instances' mutation+checkpoint sequence together, never held across a
        # saga's own dispatch cascade — Mutex is non-reentrant and recursive re-entry is real.
        @saga_mutex = Mutex.new
        @repositories = {}
        @projection_repositories = {}
        @bluebook_builders = {}
        # Eager, not lazy: avoids a race where two dispatching threads could create this
        # Hash on first access. All writes still happen at boot, single-threaded
        # (EraResolver.check!).
        @resolved_eras = {}
        # domain name -> the ordinal that superseded this boot's era, for an old checkout only.
        # RepositoryFactory.build passes it to PostgresEra#append, which refuses before the
        # INSERT — the in-process half of the era fence. Eager for the same reason as
        # @resolved_eras.
        @superseded_eras = {}
        # Eager: CapabilityGraph.new only stores the registry reference, and eager
        # construction avoids the same first-access race as @resolved_eras while
        # keeping one instance per registry.
        @capability_graph = CapabilityGraph.new(self)
        # Guards only the lazy per-domain resolution inside @saga_persistence. Must not reuse
        # @saga_mutex: checkpoint calls saga_persistence(domain) from inside
        # @saga_mutex.synchronize, and Mutex is not reentrant.
        @saga_persistence = {}
        @saga_persistence_mutex = Mutex.new
        @outbox = Outbox::Relay.new(self)
      end

      # One outbox per registry, built once here and never swapped. Can enqueue immediately;
      # a Dispatcher attaches the interpreters that let it deliver (see Runtime::Outbox).
      attr_reader :outbox

      # Stays open for the life of the registry, keyed by chapter name, so a chapter split
      # across several files (language/bluebook/*.bluebook) accumulates into one builder.
      #
      # @param name [String, Symbol] the chapter name the builder accumulates
      #   declarations for
      # @yield the block that mints a fresh builder, called only the first time
      #   `name` is asked for
      # @yieldreturn [Bluebook::DSL::BluebookBuilder] a fresh builder for `name`
      # @return [Bluebook::DSL::BluebookBuilder] the builder already open for
      #   `name`, or the block's freshly minted one on the first call
      def bluebook_builder(name)
        @bluebook_builders[name.to_s] ||= yield
      end

      # Boot-time-only, single-threaded: every add_* below runs from Hecks.collect while a
      # .bluebook/.hecksagon/.world file is being Kernel.loaded, strictly during Loader.boot,
      # before dispatcher_for hands this registry to a live, multi-threaded caller.
      # rubocop:disable Hecks/ThreadSharedIvarMutation
      # Registers a loaded chapter, keyed by its own declared name.
      #
      # @param item [Bluebook::Chapter] the loaded, judged chapter
      # @return [Bluebook::Chapter] `item`, unchanged
      def add_bluebook(item) = @bluebooks[item.name] = item

      # Tracks which .bluebook file(s) contributed to a chapter name (a boot-time loading
      # fact, never Rust-mirrored) so refuse_cross_package_bluebook_merge! can catch two
      # unrelated packages accumulating into the same name by coincidence.
      #
      # @param name [String, Symbol] the chapter name the file contributed to
      # @param path [String] the `.bluebook` file that declared it
      # @return [Array<String>] every path recorded for that chapter, `path` last
      def record_bluebook_source(name, path)
        (@bluebook_sources[name.to_s] ||= []) << path
      end

      # Merges into any wiring already registered for the domain rather than replacing it,
      # so a base .hecksagon file plus an environments/<name>.hecksagon overlay both take effect.
      #
      # @param item [Bluebook::Hecksagon] the declared wiring to register
      # @return [void]
      def add_hecksagon(item)
        existing = @hecksagons[item.domain]
        @hecksagons[item.domain] = existing ? merge_hecksagons(existing, item) : item
        mark_bounded(item.domain) if item.bounded?
      end

      # Marks `name` as a bounded context — called automatically by
      # `uses_framework` / `uses_embryonaut_bluebook`, and by
      # `add_hecksagon` when the block itself declared `bounded`.
      # A bounded chapter wraps in its own module (no Object shortcut)
      # and must have a `translates` ACL or boot refuses.
      #
      # @param name [String, Symbol] the chapter name to mark bounded
      # @return [void]
      def mark_bounded(name)
        @bounded_chapters[name.to_s] = true
      end

      # Says whether `name` is a bounded context — attached via
      # `uses_framework` / `uses_embryonaut_bluebook`, or a consumer
      # chapter that declared `bounded` on its own hecksagon.
      #
      # @param name [String, Symbol] the chapter name to check
      # @return [Boolean] whether that chapter is bounded
      def bounded?(name) = @bounded_chapters[name.to_s] ? true : false

      # Registers a loaded port, keyed by its own declared name.
      #
      # @param item [Bluebook::Port, Bluebook::DomainPort] the loaded port
      # @return [Bluebook::Port, Bluebook::DomainPort] `item`, unchanged
      def add_port(item) = @ports[item.name] = item

      # Registers a loaded adapter, keyed by its own declared name.
      #
      # @param item [Bluebook::Adapter] the loaded, judged adapter
      # @return [Bluebook::Adapter] `item`, unchanged
      def add_adapter(item) = @adapters[item.name] = item

      # Merges into any world already registered for the domain, the same shape as
      # add_hecksagon. Settings merge shallow, keyed by verb (and "verb:adapter"); an
      # overlay key wins over the base's same key, and a key only the base declares
      # survives untouched.
      #
      # @param item [Bluebook::World] the declared world settings to register
      # @return [void]
      def add_world(item)
        existing = @worlds[item.domain]
        @worlds[item.domain] = existing ? merge_worlds(existing, item) : item
      end

      # Registers a loaded translation.
      #
      # @param item [Bluebook::Translation] the loaded, judged translation
      # @return [Array<Bluebook::Translation>] every translation registered so far,
      #   `item` last
      def add_translation(item) = @translations << item

      # Declares one attribute of a domain's aggregate sensitive, called from a terminal
      # has_<category>(readable_by:). Recorded, not dispatched: Loader.boot's
      # seed_privacy_markings! turns each entry into a real Privacy::Marking.Mark once a
      # dispatcher exists.
      #
      # @param domain [String] the marked attribute's own aggregate FQN, e.g.
      #   `"Site::Registration"`
      # @param attribute_path [String] the dotted path within that aggregate, e.g.
      #   `"attendee.medications"`
      # @param category [String] the marking's own sensitivity category, e.g. `"phi"`
      # @param readable_by [String] the Governance role a read must hold, unredacted
      # @return [void]
      def add_pending_privacy_marking(domain:, attribute_path:, category:, readable_by:)
        @pending_privacy_markings << { domain: domain, attribute_path: attribute_path,
                                        category: category, readable_by: readable_by }
      end
      # rubocop:enable Hecks/ThreadSharedIvarMutation

      # {domain name => era ordinal} resolved by the boot-time era gate. Stood up eagerly
      # in initialize; this is a plain reader, not a memoizer.
      attr_reader :resolved_eras
      # Domain name -> the ordinal that superseded this boot's own era, for an old
      # checkout only.
      attr_reader :superseded_eras

      # Finds a loaded chapter by name.
      #
      # @param name [String, Symbol] the chapter's declared name
      # @return [Bluebook::Chapter, nil] the chapter, or nil if none is registered
      #   under `name`
      def bluebook(name)  = @bluebooks[name.to_s]

      # Finds a domain's registered wiring by name.
      #
      # @param name [String, Symbol] the domain name
      # @return [Bluebook::Hecksagon, nil] the domain's wiring, or nil if none is
      #   registered under `name`
      def hecksagon(name) = @hecksagons[name.to_s]

      # Finds a domain's registered world settings by name.
      #
      # @param name [String, Symbol] the domain name
      # @return [Bluebook::World, nil] the domain's world, or nil if none is
      #   registered under `name`
      def world(name)     = @worlds[name.to_s]

      # Every verb every loaded chapter declares, sorted.
      #
      # @return [Array<String>] every declared verb, across every loaded chapter
      def verbs = @bluebooks.values.flat_map(&:verbs).sort

      # The chapter that answers a role check for `domain`: the domain's own chapter, or
      # a framework member its hecksagon attaches, that declares `provides "authorization"`.
      #
      # @param domain [String, Symbol] the domain whose role checks are being resolved
      # @return [Bluebook::Chapter, nil] the chapter that answers `domain`'s role
      #   checks, or nil if none does
      def authorization_provider_for(domain)
        names = [domain.to_s, *Array(hecksagon(domain)&.member_chapters)]
        names.filter_map { |name| bluebook(name) }
             .find { |chapter| chapter.provides?(Bluebook::Capabilities::AUTHORIZATION) }
      end

      # Every loaded chapter declaring `provides "authorization"`.
      #
      # @return [Array<Bluebook::Chapter>] every loaded chapter that provides
      #   authorization
      def authorization_providers
        @bluebooks.values.select { |chapter| chapter.provides?(Bluebook::Capabilities::AUTHORIZATION) }
      end

      # The chapter that answers "who is this authenticated pair" for `domain`: the
      # domain's own chapter, or a framework member its hecksagon attaches, that
      # declares `provides "identity"`.
      #
      # @param domain [String, Symbol] the domain whose identity chapter is being resolved
      # @return [Bluebook::Chapter, nil] the chapter that answers `domain`'s identity
      #   questions, or nil if none does
      def identity_provider_for(domain)
        names = [domain.to_s, *Array(hecksagon(domain)&.member_chapters)]
        attached = names.filter_map { |name| bluebook(name) }
                        .find { |chapter| chapter.provides?(Bluebook::Capabilities::IDENTITY) }
        return attached if attached

        # Falls back to any loaded chapter: a consuming domain often wires Identity as
        # Hecks.hecksagon "Identity" rather than via uses_framework, so it's loaded but
        # not listed on the consumer's own hexagon.
        @bluebooks.values.find { |chapter| chapter.provides?(Bluebook::Capabilities::IDENTITY) }
      end

      # The chapter that answers "who may sign in" for `domain`: the domain's own
      # chapter, a framework member, or a vendored embryonaut bluebook it attaches,
      # that declares `provides "membership"`.
      #
      # Vendored packages are included here (unlike `authorization_provider_for`)
      # because membership ships as a vendored embryonaut_bluebooks chapter, not a
      # framework member.
      #
      # @param domain [String, Symbol] the domain whose sign-in aggregate is being resolved
      # @return [Bluebook::Chapter, nil] the chapter that answers `domain`'s membership
      #   questions, or nil if none does
      def membership_provider_for(domain)
        vendored_provider_for(domain, Bluebook::Capabilities::MEMBERSHIP)
      end

      # The chapter that answers the guest newsletter signup for `domain`: the domain's
      # own chapter, a framework member, or a vendored embryonaut bluebook it attaches,
      # that declares `provides "newsletter"`.
      #
      # @param domain [String, Symbol] the domain whose newsletter chapter is being resolved
      # @return [Bluebook::Chapter, nil] the chapter that answers `domain`'s newsletter
      #   signup, or nil if none does
      def newsletter_provider_for(domain)
        vendored_provider_for(domain, Bluebook::Capabilities::NEWSLETTER)
      end

      # The chapter that answers sending a newsletter issue for `domain` —
      # resolved the same way as `newsletter_provider_for`, by what it
      # declares (`provides "newsletter_issues"`). Nil when none does.
      #
      # @param domain [String, Symbol] the domain whose issue-sending chapter is being resolved
      # @return [Bluebook::Chapter, nil] the chapter that answers `domain`'s issue sending,
      #   or nil if none does
      def newsletter_issues_provider_for(domain)
        vendored_provider_for(domain, Bluebook::Capabilities::NEWSLETTER_ISSUES)
      end

      # The chapter that answers scheduling sessions and registrations for `domain`,
      # resolved the same way as `payments_provider_for`, by declaring `provides "registrations"`.
      #
      # @param domain [String, Symbol] the domain whose registrations chapter is being resolved
      # @return [Bluebook::Chapter, nil] the chapter that answers `domain`'s registrations,
      #   or nil if none does
      def registrations_provider_for(domain)
        vendored_provider_for(domain, Bluebook::Capabilities::REGISTRATIONS)
      end

      # The chapter that owns the business's payment-processor connection for
      # `domain` — resolved by what it declares (`provides "payment_connection"`).
      # Nil when none does.
      #
      # @param domain [String, Symbol] the domain whose payment-connection chapter is
      #   being resolved
      # @return [Bluebook::Chapter, nil] the chapter that owns `domain`'s payment connection,
      #   or nil if none does
      def payment_connection_provider_for(domain)
        vendored_provider_for(domain, Bluebook::Capabilities::PAYMENT_CONNECTION)
      end

      # The chapter that takes payments for `domain`: the domain's own chapter, a
      # framework member, or a vendored embryonaut bluebook it attaches, that
      # declares `provides "payments"`.
      #
      # @param domain [String, Symbol] the domain whose payments chapter is being resolved
      # @return [Bluebook::Chapter, nil] the chapter that takes `domain`'s payments, or nil
      #   if none does
      def payments_provider_for(domain)
        vendored_provider_for(domain, Bluebook::Capabilities::PAYMENTS)
      end

      # The chapter that provides `capability` for `domain`: the domain's own chapter,
      # a framework member its hecksagon attaches, or a vendored embryonaut bluebook
      # it attaches, that declares it.
      #
      # Falls back to any loaded chapter, since a consuming domain often wires a
      # vendored chapter as its own `Hecks.hecksagon "Name"` rather than via
      # `uses_embryonaut_bluebook`, so it's loaded but not listed on the consumer's hexagon.
      #
      # @param domain [String, Symbol] the domain the provider is resolved for
      # @param capability [String] the capability's name, such as
      #   `Bluebook::Capabilities::MEMBERSHIP`
      # @return [Bluebook::Chapter, nil] the providing chapter, or nil if none loaded does
      def vendored_provider_for(domain, capability)
        hexagon = hecksagon(domain)
        vendored = Array(hexagon&.vendored_bluebooks).map { |name| Naming.pascal(name) }
        names = [domain.to_s, *Array(hexagon&.member_chapters), *vendored]
        attached = names.filter_map { |name| bluebook(name) }
                        .find { |chapter| chapter.provides?(capability) }
        return attached if attached

        @bluebooks.values.find { |chapter| chapter.provides?(capability) }
      end

      # Resolves and memoizes `aggregate`'s authoritative repository.
      #
      # @param domain [String, Symbol] name of the domain `aggregate` belongs to
      # @param aggregate [Bluebook::Aggregate] the aggregate to resolve a repository for
      # @return [Persistence::AppendOnly] repository over the aggregate's authoritative
      #   adapter, or over a `Memory` adapter when the domain declares no hecksagon
      # @raise [Runtime::WiringError] if the aggregate has no authoritative bind, more than
      #   one, or a bind with a role this port does not support; or if the bound adapter is
      #   unknown, answers a different verb, is given a setting it does not declare, has no
      #   Ruby implementation, or lacks a method its port's `answers` list or the
      #   append-only contract (`append`, `project`, `entries`) requires
      def repository(domain, aggregate)
        @repositories[[domain.to_s, aggregate.hecks_name]] ||= Ports::Persistence.repository(self, domain, aggregate)
      end

      # Records one policy reaction on the shared log, and on every collection open on this
      # thread (see `collecting_reactions`).
      #
      # @param record [Hash{Symbol => Object}] the reaction's outcome
      # @return [void]
      # rubocop:disable-next Hecks/ThreadSharedIvarMutation
      def log_reaction(record)
        @reaction_log << record
        Array(Thread.current[REACTION_SINKS]).each { |sink| sink << record }
      end

      # Collects the reactions logged on this thread while the block runs, so one dispatch
      # reads exactly its own even when other threads dispatch on the same registry. Nested
      # dispatches (a reaction that dispatches) each collect, and the outer one sees theirs too.
      #
      # @yield [Array<Hash>] the collection, filled as reactions are logged
      # @return [Object] what the block returns
      def collecting_reactions
        sinks = (Thread.current[REACTION_SINKS] ||= [])
        sink  = []
        sinks << sink
        yield sink
      ensure
        sinks&.delete_if { |candidate| candidate.equal?(sink) }
      end

      # Clears everything a dispatch produced (logs, saga instances, repositories); leaves
      # what booting the files produced (bluebooks, hecksagons, ports, adapters, worlds,
      # resolved eras) untouched.
      #
      # Repositories are dropped, not emptied, so a fresh Memory adapter starts empty while
      # a durable one still sees what it persisted. Single-threaded caller only
      # (Behaviors::Expectations.run_one runs one test at a time).
      #
      # @return [Runtime::Registry] self
      # rubocop:disable-next Hecks/ThreadSharedIvarMutation
      def reset_runtime_state!
        @event_log.clear
        @reaction_log.clear
        @saga_log.clear
        @saga_dispatch_log.clear
        @policy_dispatch_log.clear
        @saga_instances.clear
        @repositories = {}
        @projection_repositories = {}
        @outbox.log.clear
        rehydrate_sagas!
        self
      end

      # Built eagerly in `initialize`; this is a plain reader, not a memoizer.
      # `spec/runtime/capability_graph_spec.rb` asserts the same instance comes back every call.
      attr_reader :capability_graph

      # Resolves and memoizes the repository to read `aggregate` from — a caught-up
      # projection when one is bound and current, otherwise the authoritative repository.
      #
      # @param domain [String, Symbol] name of the domain `aggregate` belongs to
      # @param aggregate [Bluebook::Aggregate] the aggregate to resolve a read
      #   repository for
      # @return [Persistence::AppendOnly] the projection repository when one is bound
      #   and caught up with the authoritative store; the authoritative repository
      #   otherwise
      # @raise [Runtime::WiringError] if the authoritative or projection bind cannot
      #   be resolved
      def read_repository(domain, aggregate)
        key = [domain.to_s, aggregate.hecks_name]
        binding = Ports::Projection.binds_for(self, domain, aggregate).first
        return repository(domain, aggregate) unless binding

        projection = (@projection_repositories[key] ||= begin
          projection = Ports::Persistence::RepositoryFactory.build(self, domain, aggregate, binding,
                                                                   recover: true, settings_verb: Ports::Projection::VERB)
          projection
        end)
        authoritative = repository(domain, aggregate)
        projection_current?(projection, authoritative) ? projection : authoritative
      end

      # Reports whether `projection`'s own journal entries and rows agree with
      # `authoritative`'s, entry-for-entry.
      #
      # @param projection [Persistence::AppendOnly] the projection repository to check
      # @param authoritative [Persistence::AppendOnly] the authoritative repository to
      #   check `projection` against
      # @return [Boolean] true when `projection` holds the same entries and rows as
      #   `authoritative`, in the same order; false on any mismatch, or if comparing
      #   them raises
      def projection_current?(projection, authoritative)
        projected_entries = projection.entries
        source_entries = authoritative.entries
        return false unless projected_entries.length == source_entries.length
        return false unless projected_entries.zip(source_entries).all? do |projected, source|
          projected.operation == source.operation && projected.id == source.id && projected.state == source.state
        end

        projected_rows = projection.all.map(&:to_h).sort_by { |row| row.fetch(:id).to_s }
        source_rows = authoritative.all.map(&:to_h).sort_by { |row| row.fetch(:id).to_s }
        projected_rows == source_rows
      rescue StandardError
        false
      end

      # Concatenates every list-shaped fact from base and overlay. `binds` is additive too:
      # an overlay rebinding an aggregate is meant to shadow the base's bind at resolution
      # time, not erase it — `Ports::Persistence::BindingPolicy.resolve`'s "exactly one
      # authoritative bind" check is what actually catches a genuine double-bind.
      #
      # @param base [Bluebook::Hecksagon] the domain's already-registered wiring
      # @param overlay [Bluebook::Hecksagon] the newly loaded block's own wiring to
      #   fold in
      # @return [Bluebook::Hecksagon] a new wiring with every list-shaped fact
      #   concatenated, `base` then `overlay`
      def merge_hecksagons(base, overlay)
        # Order-independent: list facts uniq, so loading context_map before or after the
        # domain file yields the same merged hecksagon.
        Bluebook::Hecksagon.new(
          domain:             base.domain,
          binds:              base.binds + overlay.binds,
          subscriptions:      (base.subscriptions + overlay.subscriptions).uniq,
          framework_members:  (base.framework_members + overlay.framework_members).uniq,
          vendored_bluebooks: (base.vendored_bluebooks + overlay.vendored_bluebooks).uniq,
          attached_chapters:  (base.attached_chapters + overlay.attached_chapters).uniq,
          bounded:            base.bounded? || overlay.bounded?,
          translates:         (base.translates + overlay.translates).uniq
        )
      end

      # Scalars (`realm`, `latest`, `default_database`, `default_adapter`): the overlay's
      # value wins when present, else the base's survives. `settings` is a shallow merge
      # keyed by verb (and `"verb:adapter"`); an overlay key replaces the base's whole
      # resolved hash for that key, it does not deep-merge within it.
      #
      # @param base [Bluebook::World] the domain's already-registered world
      # @param overlay [Bluebook::World] the newly loaded block's own world to fold in
      # @return [Bluebook::World] a new world with `overlay`'s scalars winning when
      #   present, and `settings` shallow-merged, `overlay`'s keys winning
      def merge_worlds(base, overlay)
        Bluebook::World.new(
          domain:           base.domain,
          realm:            overlay.realm || base.realm,
          latest:           overlay.latest || base.latest,
          settings:         base.settings.merge(overlay.settings),
          default_database: overlay.default_database || base.default_database,
          default_adapter:  overlay.default_adapter || base.default_adapter
        )
      end
    end
  end
end
