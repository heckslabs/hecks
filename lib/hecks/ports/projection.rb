require_relative "persistence"
require_relative "persistence/repository_factory"
require_relative "../runtime/registry"

module Hecks
  module Ports
    # Projection is a read-side port. Its stores are rebuildable consumers of
    # authoritative entries and never participate in command decisions.
    module Projection
      NAME = "projection"
      VERB = "projected_by"

      module_function

      def binds_for(registry, domain, aggregate)
        registry.hecksagon(domain)&.binds_for(aggregate.hecks_name, VERB) || []
      end

      def worker(registry, domain, aggregate, policy: :refresh)
        bind = binds_for(registry, domain, aggregate).first
        return unless bind

        authoritative = Persistence.repository(registry, domain, aggregate)
        target = Persistence::RepositoryFactory.build(registry, domain, aggregate, bind,
                                                      recover: true, settings_verb: VERB)
        Worker.new(authoritative, target, policy: policy)
      end

      class Worker
        attr_reader :projection

        def initialize(authoritative, projection, policy: :refresh)
          @authoritative = authoritative
          @projection = projection
          @policy = policy.to_sym
        end

        # Invoke from a separate process or scheduler. The command-side write
        # path never calls this method.
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
          entries.drop(present.length).each { |entry| @projection.append(entry); @projection.project(entry) }
          @projection
        end

        def checkpoint = @projection.entries.length

        private

        def same_entry?(left, right) = left.operation == right.operation && left.id == right.id && left.state == right.state

        def consistent?(entries, present)
          present.length <= entries.length && entries.first(present.length).zip(present).all? { |left, right|
            same_entry?(left, right)
          }
        end
      end

      # The authoritative append-only journal is the durable projection queue.
      # It is committed before a worker sees it; projection entries are the
      # worker's durable checkpoint, so delivery is at-least-once and safe to replay.
      class Queue
        def initialize(authoritative) = @authoritative = authoritative
        def entries = @authoritative.entries
      end
    end
  end
end
