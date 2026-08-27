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

        # The only two policies anything in this codebase ever passes
        # (`bin/project`, every spec) — there is no third, legitimate
        # "lenient append" policy on record anywhere. Before this, any
        # value OTHER than the exact symbol `:strict` silently fell
        # through the `consistent?` check below and appended onto
        # divergent history without a word — not just a real typo like
        # `:strikt`, but a caller-supplied String `"strict"` too (this
        # duck-typed fine via `policy.to_sym`, but that was luck, not a
        # contract: nothing here declared what a valid policy even was).
        # Refusing loudly at construction, once, for anything outside
        # this list turns a silent no-op into an immediate, named error
        # — the "refuse rather than silently skip" reading of L1, since
        # `:strict` really is meant to be the only enforcing contract.
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
