require_relative "registry/verification"
require_relative "registry/saga_persistence"
require_relative "outbox"
require_relative "../naming"

module Hecks
  module Runtime
    class WiringError < StandardError; end

    # The collections a boot gathers — bluebooks, hexagons, ports, adapters,
    # worlds, the logs — and how a repository is resolved from them. The
    # wiring gate lives in registry/verification.rb, saga persistence
    # resolution in registry/saga_persistence.rb.
    class Registry
      include Verification
      include SagaPersistence

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
        # A DECLARATIVE FACT, NOT YET A DISPATCHED ONE — `AggregateDoor#
        # mark_sensitive` (called from a `.hecksagon` file, the same way
        # `port`/`persisted_by` already are) appends here at
        # hecksagon-build time; `Runtime::Loader.boot`'s own post-dispatcher
        # step turns each entry into a real `Privacy::Marking.Mark`,
        # idempotently, the same "declared here, taken effect once boot
        # actually has a dispatcher" shape `redrive_outbox!` already has.
        @pending_privacy_markings = []
        # **Additive, Ruby-only** — never merged into saga_log/reaction_log.
        # rust/src/kernel/orchestrate.rs ports those two arrays' exact
        # shape byte-for-byte (spec/rust_conformance_spec.rb's own
        # equality check) — a landmine found by reading that spec before
        # touching anything, not by hitting it. These carry the raw
        # inputs a dispatch's own argument binding was resolved from
        # (SagaInterpreter#deliver_saga_dispatch / PolicyInterpreter#
        # trigger_args), for Properties.dispatch_binding_fidelity's own
        # independent re-derivation — a fact neither existing log
        # records at all, so there is nothing here for Rust to have
        # matched or drifted from.
        @saga_dispatch_log   = []
        @policy_dispatch_log = []
        @saga_instances = Hash.new { |h, k| h[k] = {} }
        # Guards `saga_instances`' own mutation+checkpoint sequence
        # (`SagaInterpreter`'s 4 write points, §7) — the same shape of
        # hazard this codebase's own prior audit already flagged for
        # `Dispatcher#reenter`'s reaction-depth counter (M20: a
        # thread-shared ivar with no lock, since fixed by moving it to
        # `Thread.current`, dispatcher.rb), made meaningfully easier to
        # hit here once a persistence write sits in the same critical
        # section. Held across the in-memory
        # mutation and the checkpoint write together, never across a
        # saga's own dispatch cascade — see `SagaInterpreter#advance_saga`'s
        # own comment for why that distinction matters (non-reentrant
        # Mutex, recursive re-entry is real).
        @saga_mutex = Mutex.new
        @repositories = {}
        @projection_repositories = {}
        @bluebook_builders = {}
        # **Eager, not lazy** — see `#resolved_eras`'s own comment for why. Built
        # here rather than `@resolved_eras ||= {}` on first access so there is
        # no window, post-boot, where two concurrently dispatching threads
        # could race creating this Hash (Hecks/ThreadSharedIvarMutation; the
        # same shape of hazard `Dispatcher#reenter`'s `@reaction_depth` was
        # fixed for). Every write into it still only ever happens at boot,
        # single-threaded (`EraResolver.check!`, a `:pre_verify` boot gate) —
        # this only removes the race on standing up the container itself for
        # a boot with no era-plugin domain at all, whose first touch would
        # otherwise be a live dispatch's own `RepositoryFactory.build` read.
        @resolved_eras = {}
        # The sibling fact `EraResolver.check!` records for an old checkout:
        # domain name -> the newest held ordinal that superseded the era this
        # boot resolved to; absent for every domain booting the current era.
        # `RepositoryFactory.build` hands it to the adapter as
        # `superseded_by:`, and `PostgresEra#append` refuses on it before
        # ever issuing an INSERT — the in-process half of the era fence, the
        # half that holds even for a connection row-level security cannot
        # bite (BUG#24). Eager for exactly the reason `@resolved_eras` is.
        @superseded_eras = {}
        # **Eager, not lazy** — see `#capability_graph`'s own comment for why.
        # `CapabilityGraph.new` only stores the registry reference; there is
        # no reason to defer it, and doing so removes the exact same
        # first-access race `#resolved_eras` above does, while preserving the
        # "same instance every call" identity `spec/runtime/capability_graph_
        # spec.rb` already requires.
        @capability_graph = CapabilityGraph.new(self)
        # `@saga_persistence` itself is eager (see `#saga_persistence`'s own
        # comment) — only the per-domain resolution inside it is genuinely
        # expensive and lazy, guarded by this dedicated mutex. Not the same
        # mutex as `@saga_mutex`: `checkpoint` (saga_interpreter.rb) calls
        # `saga_persistence(domain)` from inside an `@saga_mutex.synchronize`
        # block, so reusing `@saga_mutex` here would deadlock the very first
        # time a saga advanced (a `Mutex` is not reentrant — the exact
        # warning `@saga_mutex`'s own comment already gives for a different
        # reason).
        @saga_persistence = {}
        @saga_persistence_mutex = Mutex.new
        @outbox = Outbox::Relay.new(self)
      end

      # **The outbox relay** — one per registry, for its whole life (built
      # here, never swapped, so no thread ever sees a different one).
      # It can enqueue from the moment the registry exists; a Dispatcher
      # attaches the interpreters that let it deliver. See
      # `Runtime::Outbox`.
      attr_reader :outbox

      # The builder stays open for the life of this registry, keyed by chapter
      # name — see the comment on `BluebookBuilder.build`. A chapter split across
      # several files (`language/bluebook/*.bluebook`, all `Hecks.bluebook "Bluebook"`)
      # needs its declarations to accumulate into one builder rather than each
      # file minting its own and silently discarding the one before.
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

      # Boot-time-only, single-threaded — every `add_*` below (through
      # `add_translation`) is called exclusively from `Hecks.collect`
      # (hecks.rb), which is what `Hecks.bluebook`/`.hecksagon`/`.port`/
      # `.adapter`/`.world`/`.translation` run inside while a `.bluebook`/
      # `.hecksagon`/`.world` file is being `Kernel.load`ed — i.e. strictly
      # during `Loader.boot`/`.boot_files`, before `dispatcher_for` ever
      # hands this registry to a live, multi-threaded caller. Nothing
      # downstream of boot ever calls these — verified by grepping every
      # call site in lib/ and spec/ before writing this — so unlike
      # `#resolved_eras`/`#capability_graph`/`#saga_persistence` (each
      # reachable from live dispatch, and fixed for real above/in
      # registry/saga_persistence.rb) there is no concurrent caller for
      # `Hecks/ThreadSharedIvarMutation` to actually be warning about here.
      # rubocop:disable Hecks/ThreadSharedIvarMutation
      # Registers a loaded chapter, keyed by its own declared name.
      #
      # @param item [Bluebook::Chapter] the loaded, judged chapter
      # @return [Bluebook::Chapter] `item`, unchanged
      def add_bluebook(item) = @bluebooks[item.name] = item

      # PROVENANCE, SIDE-CHANNEL — which real `.bluebook` file(s)
      # contributed to a chapter name, never part of the exported IR (a
      # boot-time loading fact, not a domain fact) and never Rust-mirrored
      # (the same "additive, Ruby-only" shape `@translations` above already
      # is). Legitimate accumulation (several files declaring the SAME
      # chapter name on purpose — `lib/hecks/language/bluebook/*.bluebook`
      # all open `Hecks.bluebook "Bluebook"`) pushes more than one path
      # here too; that alone is not a problem. What this exists to let
      # `refuse_cross_package_bluebook_merge!` (registry/verification.rb)
      # catch is TWO UNRELATED PACKAGES accumulating into the same name by
      # coincidence — a stale vendored fork's own copy of a real gem's
      # chapter, still reachable on the load path, silently merging its
      # aggregates into the real one via this exact accumulation mechanism.
      def record_bluebook_source(name, path)
        (@bluebook_sources[name.to_s] ||= []) << path
      end

      # Merged, not replaced — recovered, not new (see Runtime::Loader
      # .boot's own comment for the provenance). A domain's hecksagon can
      # now load in more than one block for the same domain (base file
      # plus an `environments/<name>.hecksagon` overlay), and the second
      # block should add to what the first declared, not silently
      # discard it.
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

      # Merged, not replaced — the same generalization for `World` that
      # `add_hecksagon` above recovers for `Hecksagon`: an
      # `environments/<name>.world` overlay (or a host-owned tenancy
      # overlay world, same mechanism) can now add or override settings
      # for a domain a base `.world` file already declared, without
      # restating everything the base file said. Settings merge shallow,
      # keyed exactly the way WorldBuilder already stores them (both the
      # bare verb key and the `"verb:adapter"` qualified key point at the
      # same resolved hash) — an overlay's key wins over the base's same
      # key; a key only the base declares survives untouched.
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

      # Declares one attribute of one domain's own aggregate sensitive — called from a
      # terminal `has_<category>(readable_by:)` on a `Bluebook::DSL::AttributePath`
      # (reached by chaining off a bare `Domain::Aggregate` inside a `.hecksagon` file
      # being `Kernel.load`ed, or off an already-installed `AggregateDoor`), same timing
      # (and same thread-safety argument, above) as `add_bluebook`/`add_port`. Recorded,
      # not dispatched: `Runtime::Loader.boot`'s own `seed_privacy_markings!` turns each
      # entry into a real `Privacy::Marking.Mark` once a dispatcher exists.
      #
      # @param domain [String] the marked attribute's own aggregate FQN, e.g.
      #   `"Lifeadelics::Registration"`
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

      # {domain name => era ordinal} as resolved by the boot-time era
      # gate. A lineage adapter writes into its own era's partition —
      # which, for an old checkout booting a held-but-superseded shape,
      # is not the newest one. The Hash itself is stood up in `initialize`
      # (see that comment) — this is a plain reader, not a memoizer;
      # `Hecks/ThreadSharedIvarMutation` is the reason there is no `||=`
      # left here to flag.
      attr_reader :resolved_eras
      # Domain name -> the ordinal that superseded this boot's own era, for
      # an old checkout only — see `initialize`'s own comment on it.
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

      # The chapter that answers a role check for `domain` — the domain's
      # own chapter, or any framework member its hecksagon attaches, that
      # declares `provides "authorization"`. Nil when none does. Replaces
      # every check for the literal name "Governance": Governance is
      # recognised by what it declares, and a chapter that declares the
      # same thing is recognised the same way.
      #
      # @param domain [String, Symbol] the domain whose role checks are being resolved
      # @return [Bluebook::Chapter, nil] the chapter that answers `domain`'s role
      #   checks, or nil if none does
      def authorization_provider_for(domain)
        names = [domain.to_s, *Array(hecksagon(domain)&.framework_members)]
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

      # The chapter that answers "who is this authenticated pair" for
      # `domain` — the domain's own chapter, or any framework member its
      # hecksagon attaches, that declares `provides "identity"`. Nil when
      # none does. Replaces every check for the literal name "Identity":
      # Identity is recognised by what it declares (Register/Link/ResolvedBy),
      # and a chapter that declares the same thing is recognised the same way.
      #
      # @param domain [String, Symbol] the domain whose identity chapter is being resolved
      # @return [Bluebook::Chapter, nil] the chapter that answers `domain`'s identity
      #   questions, or nil if none does
      def identity_provider_for(domain)
        names = [domain.to_s, *Array(hecksagon(domain)&.framework_members)]
        attached = names.filter_map { |name| bluebook(name) }
                        .find { |chapter| chapter.provides?(Bluebook::Capabilities::IDENTITY) }
        return attached if attached

        # Sibling hecksagons — a consuming domain often wires Identity as
        # `Hecks.hecksagon "Identity"` (so Register can attach Governance
        # on that named hexagon), not only via uses_framework on the
        # consuming domain. The chapter is loaded; it just isn't listed
        # on the consumer's own hexagon.
        @bluebooks.values.find { |chapter| chapter.provides?(Bluebook::Capabilities::IDENTITY) }
      end

      # The chapter that answers "who may sign in" for `domain` — the
      # domain's own chapter, any framework member its hecksagon attaches,
      # or any vendored embryonaut bluebook it attaches, that declares
      # `provides "membership"`. Nil when none does. Replaces rust/host's
      # own HECKS_MEMBERSHIP_AGGREGATE env var: Membership is recognised
      # by what it declares (Person.Admit/GrantAccess/All), and a chapter
      # that declares the same thing (Embryonaut::Member, say) is
      # recognised the same way.
      #
      # Vendored packages are included here and not in
      # `authorization_provider_for` because membership is a vendored
      # embryonaut_bluebooks chapter (`uses_embryonaut_bluebook
      # "membership"`), not a framework member shipped inside hecks.
      # `Naming.pascal` is the same directory-to-chapter convention
      # `EmbryonautBluebook.load!` already uses.
      #
      # @param domain [String, Symbol] the domain whose sign-in aggregate is being resolved
      # @return [Bluebook::Chapter, nil] the chapter that answers `domain`'s membership
      #   questions, or nil if none does
      def membership_provider_for(domain)
        vendored_provider_for(domain, Bluebook::Capabilities::MEMBERSHIP)
      end

      # The chapter that answers the guest newsletter signup for `domain` —
      # the domain's own chapter, a framework member, or a vendored
      # embryonaut bluebook it attaches, that declares `provides
      # "newsletter"`. Nil when none does. Newsletter is recognised by
      # what it declares (Subscribe/AddName/Confirm/Unsubscribe), so a
      # chapter that declares the same thing is recognised the same way.
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

      # The chapter that answers scheduling sessions and taking registrations
      # for `domain` — resolved the same way as `payments_provider_for`, by what
      # it declares (`provides "registrations"`). Nil when none does.
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
      # @param domain [String, Symbol] the domain whose payment-connection chapter is being resolved
      # @return [Bluebook::Chapter, nil] the chapter that owns `domain`'s payment connection,
      #   or nil if none does
      def payment_connection_provider_for(domain)
        vendored_provider_for(domain, Bluebook::Capabilities::PAYMENT_CONNECTION)
      end

      # The chapter that takes payments for `domain` — the domain's own
      # chapter, a framework member, or a vendored embryonaut bluebook it
      # attaches, that declares `provides "payments"`. Nil when none does.
      # Payments is recognised by what it declares (Initiate and the
      # processor's two verdicts), so a chapter that declares the same
      # thing is recognised the same way.
      #
      # @param domain [String, Symbol] the domain whose payments chapter is being resolved
      # @return [Bluebook::Chapter, nil] the chapter that takes `domain`'s payments, or nil
      #   if none does
      def payments_provider_for(domain)
        vendored_provider_for(domain, Bluebook::Capabilities::PAYMENTS)
      end

      # The chapter that provides `capability` for `domain`: the domain's
      # own chapter, any framework member its hecksagon attaches, or any
      # vendored embryonaut bluebook it attaches, that declares it. Falls
      # back to any loaded chapter that does, because a consuming domain
      # often wires a vendored chapter as its own `Hecks.hecksagon "Name"`
      # (so that chapter can attach Governance on that named hexagon)
      # rather than via `uses_embryonaut_bluebook` on itself — the chapter
      # is loaded, it just isn't listed on the consumer's own hexagon.
      #
      # @param domain [String, Symbol] the domain the provider is resolved for
      # @param capability [String] the capability's name, such as
      #   `Bluebook::Capabilities::MEMBERSHIP`
      # @return [Bluebook::Chapter, nil] the providing chapter, or nil if none loaded does
      def vendored_provider_for(domain, capability)
        hexagon = hecksagon(domain)
        vendored = Array(hexagon&.vendored_bluebooks).map { |name| Naming.pascal(name) }
        names = [domain.to_s, *Array(hexagon&.framework_members), *vendored]
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

      # Everything a dispatch wrote, cleared; nothing a boot declared,
      # touched. Bluebooks, hecksagons, ports, adapters, worlds and the
      # resolved eras are what loading the files produced and stay as
      # they are; the logs, the saga instances and the repositories are
      # what running commands against them produced, and go back to
      # exactly what a fresh boot of the same files hands out. Dropping
      # the repositories (rather than emptying each) is deliberate: a
      # fresh boot's own repositories are new adapter instances too, so
      # a Memory adapter starts empty and a durable one sees whatever
      # it persisted — the same reading either way. Sagas rehydrate off
      # that store again, the way `Loader.boot_files` does after
      # `verify!`.
      #
      # What this is for: a test runner that would otherwise boot a runtime
      # per test to get isolation (`Behaviors::Expectations.run_one`) — ~2s a
      # boot, 76 chess behaviours = two and a half minutes of booting the
      # same two files — can now boot once and reset between tests.
      #
      # Single-threaded caller, the same reason the `add_*` cluster above
      # is exempt — `Behaviors::Expectations.run_one` is this method's only
      # caller (verified by grep before writing this), and it runs one
      # test at a time: `Runner#run` maps over tests sequentially, and
      # `Behaviors.rspec`'s generated examples run under RSpec's own
      # single-threaded example loop. No production dispatch path calls
      # this at all — a live Puma worker pool never resets a registry out
      # from under itself mid-flight.
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

      # Built eagerly in `initialize` (see that comment) — this is a plain
      # reader, not a memoizer; `spec/runtime/capability_graph_spec.rb`
      # asserts the same instance comes back every call, which this still
      # gives, just without a lazy `||=` race on standing it up.
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

      # Recovered — see `add_hecksagon`'s own comment for provenance.
      # Concatenates every list-shaped fact; `binds` in particular is
      # additive because an overlay rebinding an aggregate (a new
      # `persisted_by` for the same aggregate/verb) is meant to shadow
      # the base's own bind at resolution time, not erase it outright —
      # `Ports::Persistence::BindingPolicy.resolve`'s own "exactly one
      # authoritative bind" check is what actually catches a genuine
      # double-bind; this merge only concatenates, it does not itself
      # decide which of two binds for the same aggregate wins.
      #
      # @param base [Bluebook::Hecksagon] the domain's already-registered wiring
      # @param overlay [Bluebook::Hecksagon] the newly loaded block's own wiring to
      #   fold in
      # @return [Bluebook::Hecksagon] a new wiring with every list-shaped fact
      #   concatenated, `base` then `overlay`
      def merge_hecksagons(base, overlay)
        # Same-name blocks concatenate regardless of which file they came
        # from (`lifeadelics.hecksagon`, `context_map.hecksagon`, an
        # environment overlay). Order-independent: list facts uniq, so
        # loading context_map before or after the domain file is the same
        # merged hecksagon. Binds stay concatenated (BindingPolicy still
        # refuses a genuine double-bind).
        Bluebook::Hecksagon.new(
          domain:             base.domain,
          binds:              base.binds + overlay.binds,
          subscriptions:      (base.subscriptions + overlay.subscriptions).uniq,
          framework_members:  (base.framework_members + overlay.framework_members).uniq,
          vendored_bluebooks: (base.vendored_bluebooks + overlay.vendored_bluebooks).uniq,
          bounded:            base.bounded? || overlay.bounded?,
          translates:         (base.translates + overlay.translates).uniq
        )
      end

      # Recovered and generalized — see `add_world`'s own comment. `realm`/
      # `latest` are scalars, so the overlay's value wins when present,
      # else the base's survives; `settings` is a shallow merge keyed by
      # verb (and `"verb:adapter"`) — an overlay entry for a key the base
      # also declares replaces that key's whole resolved hash (the same
      # all-or-nothing shape `WorldBuilder#method_missing` already builds
      # each entry as), it does not deep-merge field by field within it.
      #
      # @param base [Bluebook::World] the domain's already-registered world
      # @param overlay [Bluebook::World] the newly loaded block's own world to fold in
      # @return [Bluebook::World] a new world with `overlay`'s scalars winning when
      #   present, and `settings` shallow-merged, `overlay`'s keys winning
      def merge_worlds(base, overlay)
        Bluebook::World.new(
          domain:   base.domain,
          realm:    overlay.realm || base.realm,
          latest:   overlay.latest || base.latest,
          settings: base.settings.merge(overlay.settings)
        )
      end
    end
  end
end
