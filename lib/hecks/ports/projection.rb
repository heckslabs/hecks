require_relative "persistence"
require_relative "persistence/repository_factory"
require_relative "../runtime/registry"

module Hecks
  module Ports
    # Projection is a read-side port. Its stores are rebuildable consumers of
    # authoritative entries and never participate in command decisions.
    module Projection
      NAME = "projection".freeze
      VERB = "projected_by".freeze

      module_function

      # Lists the `projected_by` binds a domain's hecksagon declares for one aggregate.
      #
      # @param registry [Runtime::Registry] the booted registry to search
      # @param domain [String, Symbol] name of the domain the aggregate belongs to
      # @param aggregate [Bluebook::Aggregate] the aggregate to find projection binds for
      # @return [Array<Bluebook::Bind>] the binds naming the aggregate, or failing that the
      #   hecksagon's aggregate-less `projected_by` binds; `[]` if there are none or the
      #   domain declares no hecksagon
      def binds_for(registry, domain, aggregate)
        registry.hecksagon(domain)&.binds_for(aggregate.hecks_name, VERB) || []
      end

      # Builds a worker that catches one projection's store up to its authoritative journal.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve binds against
      # @param domain [String, Symbol] name of the domain the aggregate belongs to
      # @param aggregate [Bluebook::Aggregate] the aggregate being projected
      # @param policy [Symbol, String] `:refresh` (reset the store and rebuild it) or
      #   `:strict` (refuse on divergent history) — see `Worker::VALID_POLICIES`
      # @return [Ports::Projection::Worker, nil] a worker for the aggregate's first declared
      #   bind, or nil if it has no projection bind
      # @raise [Runtime::WiringError] if the aggregate's authoritative persistence bind does
      #   not resolve (see `Persistence.repository`), or the projection's adapter is unknown,
      #   answers a different verb, is given a setting it does not declare, has no Ruby
      #   implementation, or lacks a method the append-only contract requires
      # @raise [ArgumentError] if `policy` is not one of `Worker::VALID_POLICIES`
      def worker(registry, domain, aggregate, policy: :refresh)
        bind = binds_for(registry, domain, aggregate).first
        return unless bind

        authoritative = Persistence.repository(registry, domain, aggregate)
        target = Persistence::RepositoryFactory.build(registry, domain, aggregate, bind,
                                                      recover: true, settings_verb: VERB)
        Worker.new(authoritative, target, policy: policy)
      end

      # Catches one projection's store up to its authoritative journal:
      # replays whatever entries the store hasn't yet appended/projected.
      # Constructed via Projection.worker; #catch_up! runs from a
      # separate process or scheduler, never from the command-side write
      # path.
      class Worker
        # @return [Persistence::AppendOnly] the projection store this worker catches up
        attr_reader :projection

        # The only two policies anything in this codebase ever passes
        # (`bin/project`, every spec) — there is no third, legitimate
        # "lenient append" policy on record anywhere. This list is the
        # contract for what a valid policy is: `catch_up!` enforces
        # history agreement only for the exact symbol `:strict`, so any
        # other unrecognised value — a typo like `:strikt` — would fall
        # through the `consistent?` check below and append onto
        # divergent history without a word. A caller-supplied String
        # `"strict"` is accepted on purpose, normalised by `policy.to_sym`
        # in `initialize` before it is checked against this list, not by
        # the accident of duck typing.
        # Refusing loudly at construction, once, for anything outside
        # this list turns a silent no-op into an immediate, named error
        # — the "refuse rather than silently skip" reading of L1, since
        # `:strict` really is meant to be the only enforcing contract.
        VALID_POLICIES = %i[refresh strict].freeze

        # @param authoritative [Persistence::AppendOnly] the authoritative repository whose
        #   journal the projection is caught up to
        # @param projection [Persistence::AppendOnly] the projection store being caught up
        # @param policy [Symbol, String] one of `VALID_POLICIES`, as a Symbol or its String
        #   spelling
        # @raise [ArgumentError] if `policy` is not one of `VALID_POLICIES`
        def initialize(authoritative, projection, policy: :refresh)
          @authoritative = authoritative
          @projection = projection
          @policy = policy.to_sym
          unless VALID_POLICIES.include?(@policy)
            raise ArgumentError,
                  "unknown projection catch_up! policy #{@policy.inspect} — expected one of " \
                  "#{VALID_POLICIES.map(&:inspect).join(' or ')}"
          end
        end

        # Appends and projects every authoritative entry the projection store lacks.
        #
        # Invoke from a separate process or scheduler. The command-side write
        # path never calls this method.
        #
        # Under `:refresh` the store is reset first and rebuilt from the whole journal. Under
        # `:strict` the store's own entries must be a prefix of the authoritative journal
        # (same operation, id and state, in order); only the entries after that prefix are
        # replayed.
        #
        # @return [Persistence::AppendOnly] the projection store, now caught up
        # @raise [Runtime::WiringError] under `:strict`, if the projection's history is not a
        #   prefix of the authoritative journal; under `:refresh`, if the projection's
        #   adapter cannot `reset!`
        def catch_up!
          entries = Queue.new(@authoritative).entries
          present = @projection.entries
          if @policy == :refresh
            @projection.reset!
            present = []
          end
          unless consistent?(entries, present)
            raise Runtime::WiringError, "projection history does not match its authoritative history" if @policy == :strict
          end
          entries.drop(present.length).each do |entry|
            @projection.append(entry)
            @projection.project(entry)
          end
          @projection
        end

        # Counts the entries the projection store holds, which is how far it has caught up.
        #
        # @return [Integer] number of journal entries already appended to the projection
        #   store; 0 for a store that has never caught up
        def checkpoint = @projection.entries.length

        private

        def same_entry?(left, right) = left.operation == right.operation && left.id == right.id && left.state == right.state

        def consistent?(entries, present)
          present.length <= entries.length && entries.first(present.length).zip(present).all? do |left, right|
            same_entry?(left, right)
          end
        end
      end

      # The authoritative append-only journal is the durable projection queue.
      # It is committed before a worker sees it; projection entries are the
      # worker's durable checkpoint, so delivery is at-least-once and safe to replay.
      class Queue
        # @param authoritative [Persistence::AppendOnly] the authoritative repository to read
        #   entries from
        def initialize(authoritative) = @authoritative = authoritative

        # Reads the whole authoritative journal, the work a projection worker replays from.
        #
        # @return [Array<Persistence::Entry>] every committed entry, oldest first; `[]` for
        #   an empty journal
        def entries = @authoritative.entries
      end
    end
  end
end
