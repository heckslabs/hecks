require_relative "persistence"
require_relative "persistence/repository_factory"
require_relative "../runtime/registry"

module Hecks
  module Ports
    # Read-side port: rebuildable stores fed from authoritative entries, never read by commands.
    module Projection
      NAME = "projection".freeze
      VERB = "projected_by".freeze

      module_function

      def binds_for(registry, domain, aggregate)
        registry.hecksagon(domain)&.binds_for(aggregate.hecks_name, VERB) || []
      end

      # Builds a worker for the aggregate's first `projected_by` bind; nil when it has none.
      def worker(registry, domain, aggregate, policy: :refresh)
        bind = binds_for(registry, domain, aggregate).first
        return unless bind

        authoritative = Persistence.repository(registry, domain, aggregate)
        target = Persistence::RepositoryFactory.build(registry, domain, aggregate, bind,
                                                      recover: true, settings_verb: VERB)
        Worker.new(authoritative, target, policy: policy)
      end

      # Catches one projection store up to its authoritative journal; run from a separate
      # process or scheduler, never from the command-side write path.
      class Worker
        attr_reader :projection

        # Only `:strict` enforces history agreement, so an unknown policy (a typo) would append
        # onto divergent history silently; construction refuses anything else.
        VALID_POLICIES = %i[refresh strict].freeze

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

        # Appends and projects every authoritative entry the store lacks.
        #
        # `:refresh` never reads journal history — it rebuilds from the aggregate's own current
        # records, which the authoritative table already holds directly, so it stays correct
        # past a compacted journal. `:strict` verifies its own entries are a real prefix of the
        # authoritative journal, which genuinely needs that history; it refuses rather than
        # silently misreading a compacted journal's surviving rows as if they started at
        # position zero.
        def catch_up!
          return refresh! if @policy == :refresh

          compacted_through = @authoritative.respond_to?(:compacted_through) ? @authoritative.compacted_through : 0
          present = @projection.entries
          if present.length < compacted_through
            raise Runtime::WiringError,
                  ":strict catch-up needs journal history the authoritative store has already " \
                  "compacted (through sequence #{compacted_through}, this projection has only " \
                  "consumed #{present.length}) — use :refresh instead"
          end

          entries = Queue.new(@authoritative).entries
          present_tail = present.drop(compacted_through)
          unless consistent?(entries, present_tail)
            raise Runtime::WiringError, "projection history does not match its authoritative history"
          end

          entries.drop(present_tail.length).each do |entry|
            @projection.append(entry)
            @projection.project(entry)
          end
          @projection
        end

        def checkpoint = @projection.entries.length

        private

        # Resets the store and rebuilds it from the aggregate's own current records — one
        # synthetic save per live record, never a replay of deleted or superseded history.
        def refresh!
          @projection.reset!
          @authoritative.all.each do |instance|
            entry = Persistence::Entry.new(operation: "save", id: instance.id.to_s, state: instance.state.dup)
            @projection.append(entry)
            @projection.project(entry)
          end
          @projection
        end

        def same_entry?(left, right) = left.operation == right.operation && left.id == right.id && left.state == right.state

        def consistent?(entries, present)
          present.length <= entries.length && entries.first(present.length).zip(present).all? do |left, right|
            same_entry?(left, right)
          end
        end
      end

      # The authoritative journal doubles as the queue: entries are committed before a worker
      # sees them, so delivery is at-least-once and safe to replay.
      class Queue
        def initialize(authoritative) = @authoritative = authoritative

        def entries = @authoritative.entries
      end
    end
  end
end
