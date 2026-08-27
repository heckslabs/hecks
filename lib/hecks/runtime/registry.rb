require_relative "registry/verification"
require_relative "registry/saga_persistence"

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
                  :saga_dispatch_log, :policy_dispatch_log

      def initialize(root: nil)
        @root         = root
        @bluebooks    = {}
        @hecksagons   = {}
        @ports = {}
        @adapters     = {}
        @worlds       = {}
        @translations = []
        @event_log    = []
        @reaction_log = []
        @saga_log = []
        # ADDITIVE, RUBY-ONLY — never merged into saga_log/reaction_log.
        # rust/src/kernel/orchestrate.rs ports THOSE two arrays' exact
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
        # GUARDS `saga_instances`' OWN mutation+checkpoint sequence
        # (`SagaInterpreter`'s 4 write points, §7) — the same shape of
        # hazard this codebase's own prior audit already flagged for
        # `Dispatcher#reenter`'s reaction-depth counter (M20: a
        # thread-shared ivar with no lock, since fixed by moving it to
        # `Thread.current`, dispatcher.rb), made meaningfully easier to
        # hit here once a persistence write sits in the same critical
        # section. Held across the in-memory
        # mutation AND the checkpoint write together, never across a
        # saga's own dispatch cascade — see `SagaInterpreter#advance_saga`'s
        # own comment for why that distinction matters (non-reentrant
        # Mutex, recursive re-entry is real).
        @saga_mutex = Mutex.new
        @repositories = {}
        @projection_repositories = {}
        @bluebook_builders = {}
        # EAGER, NOT LAZY — see `#resolved_eras`'s own comment for why. Built
        # here rather than `@resolved_eras ||= {}` on first access so there is
        # no window, post-boot, where two concurrently dispatching threads
        # could race creating this Hash (Hecks/ThreadSharedIvarMutation; the
        # same shape of hazard `Dispatcher#reenter`'s `@reaction_depth` was
        # fixed for). Every WRITE into it still only ever happens at boot,
        # single-threaded (`EraResolver.check!`, a `:pre_verify` boot gate) —
        # this only removes the race on standing up the container itself for
        # a boot with no era-plugin domain at all, whose first touch would
        # otherwise be a live dispatch's own `RepositoryFactory.build` read.
        @resolved_eras = {}
        # EAGER, NOT LAZY — see `#capability_graph`'s own comment for why.
        # `CapabilityGraph.new` only stores the registry reference; there is
        # no reason to defer it, and doing so removes the exact same
        # first-access race `#resolved_eras` above does, while preserving the
        # "same instance every call" identity `spec/runtime/capability_graph_
        # spec.rb` already requires.
        @capability_graph = CapabilityGraph.new(self)
        # `@saga_persistence` itself is eager (see `#saga_persistence`'s own
        # comment) — only the PER-DOMAIN resolution inside it is genuinely
        # expensive and lazy, guarded by this dedicated mutex. NOT the same
        # mutex as `@saga_mutex`: `checkpoint` (saga_interpreter.rb) calls
        # `saga_persistence(domain)` from INSIDE an `@saga_mutex.synchronize`
        # block, so reusing `@saga_mutex` here would deadlock the very first
        # time a saga advanced (a `Mutex` is not reentrant — the exact
        # warning `@saga_mutex`'s own comment already gives for a different
        # reason).
        @saga_persistence = {}
        @saga_persistence_mutex = Mutex.new
      end

      # THE BUILDER STAYS OPEN FOR THE LIFE OF THIS REGISTRY, keyed by chapter
      # name — see the comment on `BluebookBuilder.build`. A chapter split across
      # several files (`language/bluebook/*.bluebook`, all `Hecks.bluebook "Bluebook"`)
      # needs its declarations to accumulate into ONE builder rather than each
      # file minting its own and silently discarding the one before.
      def bluebook_builder(name)
        @bluebook_builders[name.to_s] ||= yield
      end

      # BOOT-TIME-ONLY, SINGLE-THREADED — every `add_*` below (through
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
      def add_bluebook(item) = @bluebooks[item.name] = item

      # MERGED, NOT REPLACED — RECOVERED, not new (see Runtime::Loader
      # .boot's own comment for the provenance). A domain's hecksagon can
      # now load in more than one block for the same domain (base file
      # plus an `environments/<name>.hecksagon` overlay), and the second
      # block should ADD to what the first declared, not silently
      # discard it.
      def add_hecksagon(item)
        existing = @hecksagons[item.domain]
        @hecksagons[item.domain] = existing ? merge_hecksagons(existing, item) : item
      end

      def add_port(item) = @ports[item.name] = item
      def add_adapter(item) = @adapters[item.name] = item

      # MERGED, NOT REPLACED — the same generalization for `World` that
      # `add_hecksagon` above recovers for `Hecksagon`: an
      # `environments/<name>.world` overlay (or a host-owned tenancy
      # overlay world, same mechanism) can now add or override settings
      # for a domain a base `.world` file already declared, without
      # restating everything the base file said. Settings merge shallow,
      # keyed exactly the way WorldBuilder already stores them (both the
      # bare verb key and the `"verb:adapter"` qualified key point at the
      # same resolved hash) — an overlay's key wins over the base's same
      # key; a key only the base declares survives untouched.
      def add_world(item)
        existing = @worlds[item.domain]
        @worlds[item.domain] = existing ? merge_worlds(existing, item) : item
      end

      def add_translation(item) = @translations << item
      # rubocop:enable Hecks/ThreadSharedIvarMutation

      # {domain name => era ordinal} as resolved by the boot-time era
      # gate. A lineage adapter writes into ITS OWN era's partition —
      # which, for an old checkout booting a held-but-superseded shape,
      # is not the newest one. The Hash itself is stood up in `initialize`
      # (see that comment) — this is a plain reader, not a memoizer;
      # `Hecks/ThreadSharedIvarMutation` is the reason there is no `||=`
      # left here to flag.
      attr_reader :resolved_eras

      def bluebook(name)  = @bluebooks[name.to_s]
      def hecksagon(name) = @hecksagons[name.to_s]
      def world(name)     = @worlds[name.to_s]

      def verbs = @bluebooks.values.flat_map(&:verbs).sort

      def repository(domain, aggregate)
        @repositories[[domain.to_s, aggregate.hecks_name]] ||= Ports::Persistence.repository(self, domain, aggregate)
      end

      # EVERYTHING A DISPATCH WROTE, CLEARED; NOTHING A BOOT DECLARED,
      # TOUCHED. Bluebooks, hecksagons, ports, adapters, worlds and the
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
      # What this is for: a test runner that used to boot a runtime per
      # test to get isolation (`Behaviors::Expectations.run_one`) — ~2s a
      # boot, 76 chess behaviours = two and a half minutes of booting the
      # same two files — can now boot once and reset between tests.
      #
      # SINGLE-THREADED CALLER, THE SAME REASON THE `add_*` CLUSTER ABOVE
      # IS EXEMPT — `Behaviors::Expectations.run_one` is this method's ONLY
      # caller (verified by grep before writing this), and it runs one
      # test at a time: `Runner#run` maps over tests sequentially, and
      # `Behaviors.rspec`'s generated examples run under RSpec's own
      # single-threaded example loop. No production dispatch path calls
      # this at all — a live Puma worker pool never resets a registry out
      # from under itself mid-flight.
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
        rehydrate_sagas!
        self
      end

      # Built eagerly in `initialize` (see that comment) — this is a plain
      # reader, not a memoizer; `spec/runtime/capability_graph_spec.rb`
      # asserts the SAME instance comes back every call, which this still
      # gives, just without a lazy `||=` race on standing it up.
      attr_reader :capability_graph

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

      # RECOVERED — see `add_hecksagon`'s own comment for provenance.
      # Concatenates every list-shaped fact; `binds` in particular is
      # additive because an overlay REBINDING an aggregate (a new
      # `persisted_by` for the same aggregate/verb) is meant to shadow
      # the base's own bind at resolution time, not erase it outright —
      # `Ports::Persistence::BindingPolicy.resolve`'s own "exactly one
      # authoritative bind" check is what actually catches a genuine
      # double-bind; this merge only concatenates, it does not itself
      # decide which of two binds for the same aggregate wins.
      def merge_hecksagons(a, b)
        Bluebook::Hecksagon.new(
          domain:             a.domain,
          binds:              a.binds + b.binds,
          subscriptions:      a.subscriptions + b.subscriptions,
          framework_members:  a.framework_members + b.framework_members,
          vendored_bluebooks: a.vendored_bluebooks + b.vendored_bluebooks
        )
      end

      # RECOVERED AND GENERALIZED — see `add_world`'s own comment. `realm`/
      # `latest` are scalars, so the overlay's value wins when present,
      # else the base's survives; `settings` is a shallow merge keyed by
      # verb (and `"verb:adapter"`) — an overlay entry for a key the base
      # also declares REPLACES that key's whole resolved hash (the same
      # all-or-nothing shape `WorldBuilder#method_missing` already builds
      # each entry as), it does not deep-merge field by field within it.
      def merge_worlds(a, b)
        Bluebook::World.new(
          domain:   a.domain,
          realm:    b.realm || a.realm,
          latest:   b.latest || a.latest,
          settings: a.settings.merge(b.settings)
        )
      end
    end
  end
end
