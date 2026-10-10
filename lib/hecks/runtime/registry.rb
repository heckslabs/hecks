require "forwardable"
require_relative "registry/declarations"
require_relative "registry/runtime_state"
require_relative "registry/providers"
require_relative "registry/merging"
require_relative "registry/read_repository"
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
      extend Forwardable

      include Verification
      include SagaPersistence
      include WorldDefaults
      include Providers
      include Merging
      include ReadRepository

      # The thread-local key under which open reaction collections are kept.
      REACTION_SINKS = :hecks_reaction_sinks

      attr_reader :root, :saga_mutex

      # What a boot gathers, and what a dispatch produces; each is held by `Declarations` or
      # `RuntimeState` and read through the registry.
      def_delegators :@declared, :bluebooks, :hecksagons, :ports, :adapters, :worlds, :translations,
                     :bluebook_sources, :pending_privacy_markings
      def_delegators :@state, :event_log, :reaction_log, :saga_log, :saga_instances,
                     :saga_dispatch_log, :policy_dispatch_log

      # @param root [String, nil] the booting project's root directory, the base
      #   a shared ports/adapters root and a `.world`'s own relative paths resolve
      #   against; nil for a registry with no such root
      def initialize(root: nil)
        @root         = root
        # Recorded at hecksagon-build time (AggregateModule#mark_sensitive), Loader.boot's
        # post-dispatch step turns each pending privacy marking into a real Privacy::Marking.Mark,
        # idempotently. `resolved_eras` and `superseded_eras` are eager, not lazy, so no two
        # dispatching threads race to create them; all writes still happen at boot,
        # single-threaded (EraResolver.check!).
        @declared     = Declarations.empty
        # Ruby-only logs and the saga instances, which an `@saga_mutex` guards.
        @state        = RuntimeState.fresh
        # Guards saga_instances' mutation+checkpoint sequence together, never held across a
        # saga's own dispatch cascade — Mutex is non-reentrant and recursive re-entry is real.
        @saga_mutex   = Mutex.new
        @repositories = {}
        @projection_repositories = {}
        # Eager: CapabilityGraph.new only stores the registry reference, and eager
        # construction avoids the same first-access race as `resolved_eras` while
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
        @declared.bluebook_builders[name.to_s] ||= yield
      end

      # Boot-time-only, single-threaded: every add_* below runs from Hecks.collect while a
      # .bluebook/.hecksagon/.world file is being Kernel.loaded, strictly during Loader.boot,
      # before dispatcher_for hands this registry to a live, multi-threaded caller.
      # rubocop:disable Hecks/ThreadSharedIvarMutation
      # Registers a loaded chapter, keyed by its own declared name.
      #
      # @param item [Bluebook::Chapter] the loaded, judged chapter
      # @return [Bluebook::Chapter] `item`, unchanged
      def add_bluebook(item) = @declared.bluebooks[item.name] = item

      # Drops a chapter and the open builder and source record that accumulated it, so the
      # chapter can be loaded again from nothing.
      #
      # @param name [String, Symbol] the chapter name to forget
      # @return [void]
      def forget_chapter(name)
        @declared.bluebooks.delete(name.to_s)
        @declared.bluebook_builders.delete(name.to_s)
        @declared.bluebook_sources.delete(name.to_s)
      end

      # Tracks which .bluebook file(s) contributed to a chapter name (a boot-time loading
      # fact, never Rust-mirrored) so refuse_cross_package_bluebook_merge! can catch two
      # unrelated packages accumulating into the same name by coincidence.
      #
      # @param name [String, Symbol] the chapter name the file contributed to
      # @param path [String] the `.bluebook` file that declared it
      # @return [Array<String>] every path recorded for that chapter, `path` last
      def record_bluebook_source(name, path)
        (@declared.bluebook_sources[name.to_s] ||= []) << path
      end

      # Merges into any wiring already registered for the domain rather than replacing it,
      # so a base .hecksagon file plus an environments/<name>.hecksagon overlay both take effect.
      #
      # @param item [Bluebook::Hecksagon] the declared wiring to register
      # @return [void]
      def add_hecksagon(item)
        existing = @declared.hecksagons[item.domain]
        @declared.hecksagons[item.domain] = existing ? merge_hecksagons(existing, item) : item
        mark_bounded(item.domain) if item.bounded?
      end

      # Marks `name` as a bounded context — called automatically by `attaches`, and by
      # `add_hecksagon` when the block itself declared `bounded`.
      # A bounded chapter wraps in its own module (no Object shortcut)
      # and must have a `translates` ACL or boot refuses.
      #
      # @param name [String, Symbol] the chapter name to mark bounded
      # @return [void]
      def mark_bounded(name)
        @declared.bounded_chapters[name.to_s] = true
      end

      # Says whether `name` is a bounded context — attached via `attaches`, or a consumer
      # chapter that declared `bounded` on its own hecksagon.
      #
      # @param name [String, Symbol] the chapter name to check
      # @return [Boolean] whether that chapter is bounded
      def bounded?(name) = @declared.bounded_chapters[name.to_s] ? true : false

      # Registers a loaded port, keyed by its own declared name.
      #
      # @param item [Bluebook::Port, Bluebook::DomainPort] the loaded port
      # @return [Bluebook::Port, Bluebook::DomainPort] `item`, unchanged
      def add_port(item) = @declared.ports[item.name] = item

      # Registers a loaded adapter, keyed by its own declared name.
      #
      # @param item [Bluebook::Adapter] the loaded, judged adapter
      # @return [Bluebook::Adapter] `item`, unchanged
      def add_adapter(item) = @declared.adapters[item.name] = item

      # Merges into any world already registered for the domain, the same shape as
      # add_hecksagon. Settings merge shallow, keyed by verb (and "verb:adapter"); an
      # overlay key wins over the base's same key, and a key only the base declares
      # survives untouched.
      #
      # @param item [Bluebook::World] the declared world settings to register
      # @return [void]
      def add_world(item)
        existing = @declared.worlds[item.domain]
        @declared.worlds[item.domain] = existing ? merge_worlds(existing, item) : item
      end

      # Registers a loaded translation.
      #
      # @param item [Bluebook::Translation] the loaded, judged translation
      # @return [Array<Bluebook::Translation>] every translation registered so far,
      #   `item` last
      def add_translation(item) = @declared.translations << item

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
        @declared.pending_privacy_markings << { domain: domain, attribute_path: attribute_path,
                                                category: category, readable_by: readable_by }
      end
      # rubocop:enable Hecks/ThreadSharedIvarMutation

      # `resolved_eras` is {domain name => era ordinal} resolved by the boot-time era gate;
      # `superseded_eras` is the domain name -> the ordinal that superseded this boot's own era,
      # for an old checkout only. Stood up eagerly; plain readers, not memoizers.
      def_delegators :@declared, :resolved_eras, :superseded_eras

      # Finds a loaded chapter by name.
      #
      # @param name [String, Symbol] the chapter's declared name
      # @return [Bluebook::Chapter, nil] the chapter, or nil if none is registered
      #   under `name`
      def bluebook(name)  = @declared.bluebooks[name.to_s]

      # Finds a domain's registered wiring by name.
      #
      # @param name [String, Symbol] the domain name
      # @return [Bluebook::Hecksagon, nil] the domain's wiring, or nil if none is
      #   registered under `name`
      def hecksagon(name) = @declared.hecksagons[name.to_s]

      # Finds a domain's registered world settings by name.
      #
      # @param name [String, Symbol] the domain name
      # @return [Bluebook::World, nil] the domain's world, or nil if none is
      #   registered under `name`
      def world(name)     = @declared.worlds[name.to_s]

      # Every verb every loaded chapter declares, sorted.
      #
      # @return [Array<String>] every declared verb, across every loaded chapter
      def verbs = @declared.bluebooks.values.flat_map(&:verbs).sort

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
      # The event that triggered a reaction is kept beside the log, not in the record: the record
      # is the byte-for-byte shape the Rust kernel also writes.
      #
      # @param record [Hash{Symbol => Object}] the reaction's outcome
      # @param event [String, Integer, nil] identity of the event instance the reaction answered
      # @return [void]
      # rubocop:disable-next Hecks/ThreadSharedIvarMutation
      def log_reaction(record, event: nil)
        @state.reaction_log << record
        @state.reaction_events[record] = event if event
        Array(Thread.current[REACTION_SINKS]).each { |sink| sink << record }
      end

      # The identity of the event instance a logged reaction answered.
      #
      # @param record [Hash{Symbol => Object}] a record `log_reaction` was given
      # @return [String, Integer, nil] nil for a record logged without its event
      def reaction_event(record) = @state.reaction_events[record]

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
        @state.clear
        @repositories = {}
        @projection_repositories = {}
        @outbox.log.clear
        rehydrate_sagas!
        self
      end

      # Built eagerly in `initialize`; this is a plain reader, not a memoizer.
      # `spec/runtime/capability_graph_spec.rb` asserts the same instance comes back every call.
      attr_reader :capability_graph
    end
  end
end
