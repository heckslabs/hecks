require_relative "registry/verification"
require_relative "registry/saga_persistence"

module Hecksagain
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
        # `@reaction_depth`, a thread-shared dispatcher ivar with no
        # lock, made meaningfully easier to hit once a persistence write
        # sits in the same critical section. Held across the in-memory
        # mutation AND the checkpoint write together, never across a
        # saga's own dispatch cascade — see `SagaInterpreter#advance_saga`'s
        # own comment for why that distinction matters (non-reentrant
        # Mutex, recursive re-entry is real).
        @saga_mutex = Mutex.new
        @repositories = {}
        @projection_repositories = {}
        @bluebook_builders = {}
      end

      # THE BUILDER STAYS OPEN FOR THE LIFE OF THIS REGISTRY, keyed by chapter
      # name — see the comment on `BluebookBuilder.build`. A chapter split across
      # several files (`language/bluebook/*.bluebook`, all `Hecks.bluebook "Bluebook"`)
      # needs its declarations to accumulate into ONE builder rather than each
      # file minting its own and silently discarding the one before.
      def bluebook_builder(name)
        @bluebook_builders[name.to_s] ||= yield
      end

      def add_bluebook(item)  = @bluebooks[item.name] = item
      def add_hecksagon(item) = @hecksagons[item.domain] = item
      def add_port(item) = @ports[item.name] = item
      def add_adapter(item)   = @adapters[item.name]   = item
      def add_world(item)     = @worlds[item.domain]   = item
      def add_translation(item) = @translations << item

      # {domain name => era ordinal} as resolved by the boot-time era
      # gate. A lineage adapter writes into ITS OWN era's partition —
      # which, for an old checkout booting a held-but-superseded shape,
      # is not the newest one.
      def resolved_eras = @resolved_eras ||= {}

      def bluebook(name)  = @bluebooks[name.to_s]
      def hecksagon(name) = @hecksagons[name.to_s]
      def world(name)     = @worlds[name.to_s]

      def verbs = @bluebooks.values.flat_map(&:verbs).sort

      def repository(domain, aggregate)
        @repositories[[domain.to_s, aggregate.hecks_name]] ||= Ports::Persistence.repository(self, domain, aggregate)
      end

      def capability_graph
        @capability_graph ||= CapabilityGraph.new(self)
      end

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
    end
  end
end
