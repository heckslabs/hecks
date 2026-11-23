module Hecks
  module Bluebook
    module ModelCheck
      # The check over persistence: a hecksagon that wires a store for some aggregates and neither
      # binds the rest nor sets a domain default leaves them in Memory, and their records are lost
      # at exit. An aggregate meant to stay there says so with `persisted_by("Memory")`;
      # a domain that wires nothing, or sets a default, is left alone.
      module PersistenceChecks
        # The adapters that keep nothing past the process: Memory, and DecisionFiles, a Memory store
        # filled from files that takes no write.
        MEMORY_BACKED = %w[Memory DecisionFiles].freeze

        # @param bluebook [Bluebook::Declaration] the domain being checked
        # @param hecksagon [Bluebook::Hecksagon, nil] its wiring; `nil` checks nothing
        # @return [Array<Finding>] one `:memory_in_persisted_domain` error per unbound aggregate
        def persistence_findings(bluebook, hecksagon)
          binds = persisted_binds(hecksagon)
          store = store_of(binds)
          return [] unless store

          named = binds.map(&:aggregate_name)
          unbound = bluebook.aggregates.reject { |aggregate| named.include?(aggregate.hecks_name.to_s) }
          unbound.map { |aggregate| memory_finding(bluebook, aggregate, store.adapter) }
        end

        # @return [Bluebook::Bind, nil] the store one aggregate is kept in, when the wiring has no
        #   domain default
        def store_of(binds)
          return if binds.any? { |bind| bind.aggregate.nil? }

          binds.find { |bind| durable?(bind.adapter) }
        end

        # @return [Boolean] whether the adapter keeps records past the process
        def durable?(adapter) = !MEMORY_BACKED.include?(adapter.to_s)

        # @return [Array<Bluebook::Bind>] the hecksagon's `persisted_by` binds, none without one
        def persisted_binds(hecksagon)
          return [] unless hecksagon

          hecksagon.binds.select { |bind| bind.verb.to_s == "persisted_by" }
        end

        # @return [Finding] the error naming the aggregate and the hecksagon line to add
        def memory_finding(bluebook, aggregate, adapter)
          line = "#{bluebook.name}::#{aggregate.hecks_name}.persisted_by(#{adapter.to_s.inspect})"
          Finding.new(kind: :memory_in_persisted_domain, severity: :error, subject: aggregate.hecks_name.to_s,
                      message: "#{bluebook.name}'s hecksagon persists other aggregates but binds this one to " \
                               "nothing, so it stays in Memory; add `#{line}` to the hecksagon, or " \
                               "`#{bluebook.name}::#{aggregate.hecks_name}.persisted_by(\"Memory\")` to keep it there")
        end
      end
    end
  end
end
